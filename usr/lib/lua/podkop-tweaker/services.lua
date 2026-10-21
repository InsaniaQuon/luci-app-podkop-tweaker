-- Owned IO, short interprocess resource locks and checked service operations.
local LIB = require("podkop-tweaker.lib")
local M = {}
M.podkop = { config = "/etc/config/podkop", backup = "/etc/config/podkop.auto-backup", restart_cmd = "/etc/init.d/podkop restart 2>&1" }
M.stubby = { config = "/etc/config/stubby", backup = "/etc/config/stubby.auto-backup", restart_cmd = "/etc/init.d/stubby restart 2>&1" }
M.singbox = { config = "/etc/sing-box/config.json", backup = "/etc/sing-box/config.json.auto-backup", restart_cmd = "/etc/init.d/sing-box restart 2>&1" }
M.SINGBOX_CONFIG, M.SINGBOX_BACKUP = M.singbox.config, M.singbox.backup
M.SINGBOX_MAX_SIZE = 2097152
M.ops = { podkop = { svc = M.podkop, init = "podkop", pid = "sing-box" },
    stubby = { svc = M.stubby, init = "stubby", pid = "stubby" },
    singbox = { svc = M.singbox, init = "sing-box", pid = "sing-box" } }
M.SUBS_FILE = "/etc/config/podkop-tweaker-subs.json"
M.UPDATE_LOG_FILE, M.UPDATE_LOG_MAX = "/etc/config/pt-update.log", 25
M.LOCK_ROOT = "/var/lock"
local owned, held, scopes = {}, {}, {}
local MAIN = {}
local function owner() return coroutine.running() or MAIN end
local function pack(...) return { n = select("#", ...), ... } end

function M.checked_command(command)
    return "(" .. command .. ") </dev/null 2>&1; printf '\\nPT_EXIT:%s\\n' \"$?\""
end

function M.exec_checked(command)
    local failures = {}
    local function failed(stage, err, errno, exception)
        failures[#failures + 1] = { stage = stage, error = tostring(err or "No result returned"),
            errno = errno, exception = exception or nil }
    end
    local function unknown(raw)
        local details = type(raw) == "string" and raw or ""
        for _, failure in ipairs(failures) do
            local message = "Command outcome is unknown: " .. failure.stage ..
                (failure.exception and " exception: " or " failed: ") .. failure.error ..
                (failure.errno ~= nil and (" (errno=" .. tostring(failure.errno) .. ")") or "")
            details = details .. (details ~= "" and "\n" or "") .. message
        end
        return false, details, nil, { unknown = true, errors = failures }
    end
    local opened, pipe, open_err, open_errno = pcall(function()
        return io.popen(M.checked_command(command), "r")
    end)
    if not opened then failed("open", pipe, nil, true); return unknown() end
    if not pipe then failed("open", open_err, open_errno); return unknown() end
    -- Own the descriptor directly: one complete read, then exactly one close,
    -- including when read throws. Never replay the command or an interrupted read.
    local read, raw, read_err, read_errno = pcall(function() return pipe:read("*a") end)
    local close, closed, close_err, close_errno = pcall(function() return pipe:close() end)
    if not read then failed("read", raw, nil, true); raw = nil
    elseif type(raw) ~= "string" or read_err ~= nil or read_errno ~= nil then
        failed("read", read_err or "Pipe read did not return complete text", read_errno)
    end
    if not close then failed("close", closed, nil, true)
    elseif not closed then failed("close", close_err, close_errno) end
    if #failures > 0 then return unknown(raw) end
    local details, code = raw:match("^(.*)\nPT_EXIT:([0-9]+)\n$")
    local number = code and #code <= 3 and tonumber(code) or nil
    if not number or number > 255 or tostring(number) ~= code then
        failed("marker", "Missing or invalid final PT_EXIT marker")
        return unknown(raw)
    end
    return number == 0, details, number
end

function M.background_command(command, delay)
    local body = 'trap "" HUP; '
    if delay and delay > 0 then body = body .. "sleep " .. math.floor(delay) .. "; " end
    return "sh -c " .. LIB.shell_escape(body .. command) .. " </dev/null >/dev/null 2>&1 & "
end

function M.singbox_content_check(content, empty_msg)
    if type(content) ~= "string" then return false, "Configuration must be text" end
    if not content:match("%S") then return false, empty_msg or "Configuration is empty" end
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
    local fd, err, errno = io.open(path, "rb")
    if not fd then return nil, err or "Cannot open file", errno == 2 and 2 or 5 end
    local content, read_err = M.read_stream(fd, limit or 8388608)
    local closed, close_err = fd:close()
    if not content then return nil, read_err, 5 end
    if not closed then return nil, "Cannot close file: " .. tostring(close_err), 5 end
    return content
end

-- Low-level byte writer. Production callers use it only for reserved stages;
-- this primitive does not own arbitrary paths and never unlinks them on error.
function M.write_file_checked(path, content, mode)
    if type(content) ~= "string" then return false, "Content must be text or binary bytes" end
    local fd, open_err = io.open(path, "wb")
    if not fd then return false, open_err or "Cannot write temporary file" end
    if mode and (type(mode) ~= "string" or not mode:match("^[0-7][0-7][0-7]$") or
        not LIB.exit_ok(os.execute("chmod " .. mode .. " " .. LIB.shell_escape(path) .. " 2>/dev/null"))) then
        fd:close()
        return false, "Cannot set file permissions"
    end
    local written, write_err = fd:write(content)
    local closed, close_err = fd:close()
    if not written or not closed then return false, "Cannot write file: " .. tostring(write_err or close_err or "unknown error") end
    return true
end

function M.discard_stage(stage)
    if not owned[stage] then return false, "Temporary file is not owned by this operation" end
    local removed, err, errno = os.remove(stage)
    if not removed and errno ~= 2 then return false, err or "Cannot remove owned temporary file" end
    owned[stage] = nil
    return true
end

function M.stage_file(target, content, options)
    options = options or {}
    if type(target) ~= "string" or target:sub(1, 1) ~= "/" or target:find("%c") or type(content) ~= "string" then
        return nil, "Invalid staging target or content"
    end
    local suffix = options.suffix or ".tmp-write"
    if type(suffix) ~= "string" or suffix:find("/", 1, true) or suffix:find("%c") then return nil, "Invalid staging suffix" end
    local prefix = target .. suffix .. "."
    local command = "umask 077; mktemp " .. LIB.shell_escape(prefix .. "XXXXXX") ..
        " 2>&1; printf '\\nPT_MKTEMP_EXIT:%s\\n' \"$?\""
    local pipe = io.popen(command, "r")
    if not pipe then return nil, "Cannot allocate an owned temporary file" end
    local output, read_err = M.read_stream(pipe, 4096)
    local closed = pipe:close()
    if not output or not closed then return nil, read_err or "Cannot close temporary allocator" end
    local stage, status = output:match("^(.-)\n\nPT_MKTEMP_EXIT:(%d+)\n$")
    if status ~= "0" or not stage or stage:sub(1, #prefix) ~= prefix or not stage:sub(#prefix + 1):match("^[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]$") then
        return nil, "Cannot allocate an owned temporary file: " .. output
    end
    if owned[stage] then return nil, "Temporary allocator reused an owned pathname" end
    owned[stage] = { target = target, bytes = content, mode = options.mode or (options.executable and "755" or "644"), scope = scopes[owner()] }
    local ok, err = M.write_file_checked(stage, content, "600")
    if not ok then M.discard_stage(stage); return nil, err end
    return stage
end

function M.publish_file(stage, target)
    local record = owned[stage]
    if not record or record.target ~= target then return false, "Temporary file does not belong to this target" end
    local bytes, err = M.read_file(stage, #record.bytes + 1)
    if bytes ~= record.bytes then return false, err or "Owned temporary content changed before publication" end
    local mode = record.mode
    if type(mode) ~= "string" or not mode:match("^[0-7][0-7][0-7]$") or
        not LIB.exit_ok(os.execute("chmod " .. mode .. " " .. LIB.shell_escape(stage) .. " 2>/dev/null")) then
        return false, "Cannot set file permissions"
    end
    bytes, err = M.read_file(stage, #record.bytes + 1)
    if bytes ~= record.bytes then return false, err or "Owned temporary content changed before publication" end
    local renamed, rename_err = os.rename(stage, target)
    if not renamed then return false, "Cannot apply: " .. tostring(rename_err or "rename failed") end
    owned[stage] = nil
    return true
end

function M.write_file_atomic(target, content, options)
    local stage, err = M.stage_file(target, content, options)
    if not stage then return false, err end
    local ok, publish_err = M.publish_file(stage, target)
    if not ok then M.discard_stage(stage) end
    return ok, publish_err
end

function M.with_lock(key, fn)
    if type(key) ~= "string" or not key:match("^[a-zA-Z0-9_%-]+$") or type(fn) ~= "function" then return nil, "Invalid resource lock" end
    local who = owner()
    if held[key] and held[key].owner == who then return fn() end
    local path = M.LOCK_ROOT .. (key == "singbox" and "/podkop-fragment.lock" or "/podkop-tweaker-" .. key .. ".lock")
    if not LIB.exit_ok(os.execute("mkdir " .. LIB.shell_escape(path) .. " 2>/dev/null")) then return nil, "Resource is busy or its lock is unavailable: " .. key end
    local scope, previous = {}, scopes[who]
    held[key], scopes[who] = { owner = who }, scope
    local result = pack(pcall(fn))
    scopes[who], held[key] = previous, nil
    local cleanup_err
    if not result[1] then
        local paths = {}
        for stage, record in pairs(owned) do if record.scope == scope then paths[#paths + 1] = stage end end
        for _, stage in ipairs(paths) do
            local ok, err = M.discard_stage(stage)
            if not ok then cleanup_err = err end
        end
    end
    local released = LIB.exit_ok(os.execute("rmdir " .. LIB.shell_escape(path) .. " 2>/dev/null"))
    if not result[1] then error(tostring(result[2]) .. (cleanup_err and ("; " .. cleanup_err) or "") .. (not released and "; cannot release owned lock" or ""), 0) end
    if not released then return nil, "Operation may already be applied; cannot release owned lock: " .. key, true end
    return unpack(result, 2, result.n)
end

local function resolve(value)
    if type(value) == "table" and value.svc then value = value.svc end
    for _, name in ipairs({ "podkop", "stubby", "singbox" }) do
        if value == name or value == M[name] then return M[name], name end
    end
    return nil, "Unknown service"
end

local function limit_for(name) return name == "singbox" and M.SINGBOX_MAX_SIZE or LIB.UCI_MAX_SIZE end
local function config_for(svc, name) return name == "singbox" and M.SINGBOX_CONFIG or svc.config end
local function backup_for(svc, name) return name == "singbox" and M.SINGBOX_BACKUP or svc.backup end

local function basic_validation(name, content)
    if name == "singbox" then return M.singbox_content_check(content, "Configuration is empty") end
    if type(content) ~= "string" or not content:match("%S") then return false, "Configuration is empty" end
    return LIB.validate_uci_config(content)
end

local function validate_stage(name, stage)
    if name ~= "singbox" then return true end
    local record = owned[stage]
    if not record then return false, "Validation stage is not owned", nil, "io" end
    local ok, details, code = M.exec_checked("sing-box check -c " .. LIB.shell_escape(stage))
    local current, err = M.read_file(stage, #record.bytes + 1)
    if current ~= record.bytes then return false, "Validation stage changed or cannot be read", err, "io" end
    if not ok then return false, "sing-box check failed", details, code == 1 and "invalid" or "io" end
    return true
end

function M.validate_service(value, content)
    local svc, name = resolve(value)
    if not svc then return false, name end
    local valid, err = basic_validation(name, content)
    if not valid then return false, err, nil, "invalid" end
    if name ~= "singbox" then return true end
    local stage, stage_err = M.stage_file(config_for(svc, name), content, { suffix = ".tmp-check" })
    if not stage then return false, stage_err, nil, "io" end
    local ok, check_err, details, kind = validate_stage(name, stage)
    local cleaned, cleanup_err = M.discard_stage(stage)
    if not cleaned then return false, cleanup_err, details, "io" end
    return ok, check_err, details, kind
end

function M.backup_to(source, target, required)
    local bytes, err, errno = M.read_file(source, 8388608)
    if not bytes then
        if errno == 2 and not required then return true end
        return false, err or "Cannot read backup source"
    end
    return M.write_file_atomic(target, bytes, { suffix = ".tmp" })
end

local function backup_snapshot(svc, name, bytes)
    local valid, err, details, kind = M.validate_service(svc, bytes)
    if not valid then
        if kind ~= "invalid" then return false, err or "Cannot validate backup source", details end
        return true, nil, { warning = "Current configuration is not a usable rollback source; previous backup retained: " .. tostring(err) }
    end
    return M.write_file_atomic(backup_for(svc, name), bytes, { suffix = ".tmp" })
end

function M.backup_current(value)
    local svc, name = resolve(value)
    if not svc then return false, name end
    local ok, err, metadata = M.with_lock(name, function()
        local bytes, read_err, errno = M.read_file(config_for(svc, name), limit_for(name))
        if not bytes then
            if errno == 2 then return true, nil, { missing = true } end
            return false, read_err
        end
        return backup_snapshot(svc, name, bytes)
    end)
    return ok == true, err, metadata
end

local function error_response(message, details, applied)
    return { success = false, error = message, details = details, applied = applied or nil }
end

local function lock_failure(outcome, err, uncertain)
    local response = outcome or error_response(err)
    response.success = false
    if response.error then
        response.primary_error = response.primary_error or response.error
        response.primary_details = response.primary_details or response.details
        response.details = response.error .. (response.details and ("\n" .. response.details) or "") .. "\n" .. tostring(err)
    end
    response.error, response.lock_error = err, err
    response.unknown = uncertain or response.unknown or nil
    return response
end

local function apply_locked(svc, name, content, options)
    local path, limit = config_for(svc, name), limit_for(name)
    local before, read_err, errno = M.read_file(path, limit)
    if not before and errno ~= 2 then return error_response("Cannot read current configuration", read_err) end
    local valid, validation_err = basic_validation(name, content)
    if not valid then return error_response(validation_err) end
    if options.skip_unchanged and before == content then return { success = true, unchanged = true } end
    local stage, stage_err = M.stage_file(path, content, { suffix = options.suffix })
    if not stage then return error_response("Cannot write configuration stage", stage_err) end
    local function fail(message, details)
        M.discard_stage(stage)
        return error_response(message, details)
    end
    local checked, check_err, details = validate_stage(name, stage)
    if not checked then return fail(check_err, details) end
    local current, current_err, current_errno = M.read_file(path, limit)
    if current ~= before or (not current and current_errno ~= 2) then return fail("Configuration changed during application", current_err) end
    local warning
    if options.backup ~= false and before ~= nil then
        local backed, backup_err, info = backup_snapshot(svc, name, before)
        if not backed then return fail("Cannot create backup", backup_err .. (info and ("\n" .. info) or "")) end
        warning = info and info.warning
    end
    current, current_err, current_errno = M.read_file(path, limit)
    if current ~= before or (not current and current_errno ~= 2) then return fail("Configuration changed before publication", current_err) end
    local published, publish_err = M.publish_file(stage, path)
    if not published then return fail("Cannot apply configuration", publish_err) end
    local response = options.restart == false and { success = true, applied = true } or M.restart_service(M.ops[name])
    response.applied = true
    if warning then response.warning = warning end
    return response
end

function M.apply_service(value, content, options)
    local svc, name = resolve(value)
    if not svc then return error_response(name) end
    local outcome
    local result, err, uncertain = M.with_lock(name, function()
        outcome = apply_locked(svc, name, content, options or {})
        return outcome
    end)
    if result then return result end
    return lock_failure(outcome, err, uncertain)
end

function M.restore_backup(value)
    local svc, name = resolve(value)
    if not svc then return false, name end
    local ok, err, details = M.with_lock(name, function()
        local bytes, read_err, errno = M.read_file(backup_for(svc, name), limit_for(name))
        if not bytes then return false, errno == 2 and "not_found" or "read_failed", read_err end
        local result = apply_locked(svc, name, bytes, { backup = false, restart = false, suffix = ".tmp-restore" })
        return result.success == true, result.error, result.details
    end)
    return ok == true, err, details
end

local function process_ops(value)
    if type(value) == "table" and value.svc and value.pid then return value end
    local _, name = resolve(value)
    return M.ops[name]
end

function M.service_status(value)
    local ops = process_ops(value)
    if not ops or type(ops.pid) ~= "string" or not ops.pid:match("^[A-Za-z0-9_.%-]+$") then return { error = "Unknown service process" } end
    local ok, output, code = M.exec_checked("pidof " .. LIB.shell_escape(ops.pid) .. " 2>/dev/null")
    if code == 1 and not output:match("%S") then return { running = false } end
    if not ok then return { error = "Cannot query service process", details = output } end
    if output:gsub("%d", ""):match("%S") then return { error = "Invalid service process response" } end
    local pid
    for digits in output:gmatch("%d+") do
        local n = tonumber(digits)
        if n > 0 and n <= 2147483647 and (not pid or n < pid) then pid = n end
    end
    if not pid then return { error = "Empty service process response" } end
    local response = { running = true, pid = tostring(pid) }
    local stat, err = M.read_file("/proc/" .. pid .. "/stat", 4096)
    local fields = stat and stat:match("^%d+ %b() (.+)$")
    local index = 0
    for field in (fields or ""):gmatch("%S+") do
        index = index + 1
        if index == 20 and field:match("^%d+$") then response.instance = pid .. ":" .. field; break end
    end
    if not response.instance then response.identity_error = err or "Cannot read service process identity" end
    return response
end

function M.restart_service(value)
    local ops = process_ops(value)
    if not ops then return error_response("Unknown service") end
    local before = M.service_status(ops)
    local ok, details, code = M.exec_checked(ops.svc.restart_cmd)
    local response = ok and { success = true, restarting = true } or
        error_response(code ~= nil and "Service restart command failed" or "Service restart outcome is unknown", details)
    if code == nil then response.unknown = true end
    response.command_result_known, response.command_exit_code = code ~= nil, code
    response.verification_required = true
    response.previous_running = before.running
    response.previous_instance = before.instance
    response.previous_identity_known = before.error == nil and (before.running == false or before.instance ~= nil)
    return response
end

function M.service_toggle(value, action)
    if action ~= "start" and action ~= "stop" then return error_response("Invalid action") end
    local ops = process_ops(value)
    if not ops then return error_response("Unknown service") end
    local _, name = resolve(ops)
    local outcome
    local result, err, uncertain = M.with_lock(name, function()
        local before = M.service_status(ops)
        local init = ops.init:sub(1, 1) == "/" and ops.init or ("/etc/init.d/" .. ops.init)
        local ok, details, code = M.exec_checked(LIB.shell_escape(init) .. " " .. action)
        local response
        if not ok then
            response = error_response("Service " .. action .. (code ~= nil and " command failed" or " outcome is unknown"), details)
            if code == nil then response.unknown = true end
        else
            response = M.service_status(ops)
            response.command_accepted = true
            response.success = response.error == nil and response.running == (action == "start")
            if response.success then response.applied = true
            else
                response.error = response.error or "Service command accepted, but requested state is not observed"
                response.unknown = true
            end
        end
        response.requested = action
        response.command_result_known, response.command_exit_code = code ~= nil, code
        response.verification_required, response.previous_running = true, before.running
        response.previous_instance = before.instance
        response.previous_identity_known = before.error == nil and (before.running == false or before.instance ~= nil)
        outcome = response
        return response
    end)
    if result then return result end
    return lock_failure(outcome, err, uncertain)
end

function M.rollback(value)
    local ops = process_ops(value)
    if not ops then return error_response("Unknown service") end
    local _, name = resolve(ops)
    local outcome
    local result, err, uncertain = M.with_lock(name, function()
        local restored, restore_err, details = M.restore_backup(ops.svc)
        if not restored then outcome = error_response(restore_err == "not_found" and "Backup file not found" or "Cannot restore backup", details or restore_err); return outcome end
        local response = M.restart_service(ops)
        response.applied = true
        outcome = response
        return response
    end)
    if result then return result end
    return lock_failure(outcome, err, uncertain)
end

-- Compatibility for old bool callers; all actual IO still uses owned stages.
function M.singbox_apply_checked(content, suffix, check_err_msg)
    local result = M.apply_service("singbox", content, { restart = false, suffix = suffix })
    local err = result.error
    if err == "sing-box check failed" and check_err_msg then err = check_err_msg end
    return result.success == true, err, result.details
end

return M
