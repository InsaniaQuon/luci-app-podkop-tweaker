-- Isolated native actor for native_io.py. Lua 5.1, real production services.lua,
-- real IO and OS commands; no pt_harness/VFS or production function replacement.
-- Only the checker/service commands are substituted by the Python command bridge.
-- IO wrappers guard fixture paths, journal native operations, and expose a barrier
-- immediately after a real stage open, before the production writer receives fd.
-- One explicit checker-transport fault runs native ':' without the wrapper to
-- exercise missing PT_EXIT evidence; it never fabricates a marker or IO result.
-- Run through native_io.py, which owns process joining and fixture cleanup.

local repo, root, actor, python = arg[1], arg[2], arg[3], arg[4]
assert(_VERSION == "Lua 5.1", "native IO regression requires installed Lua 5.1")
assert(repo and root and actor and python, "use tests/native_io.py")
assert(root:find("/.test_tmp/", 1, true), "fixture must be inside ROOT/.test_tmp")
assert(actor:match("^[a-z0-9-]+$"), "invalid fixture actor")
package.path = repo .. "/usr/lib/lua/?.lua;" .. repo .. "/tests/?.lua;" .. package.path

local JSON = require("pt_json")
local LIB = require("podkop-tweaker.lib")
local native_open, native_popen = io.open, io.popen
local native_remove, native_rename, native_execute = os.remove, os.rename, os.execute
local input, output = io.stdin, io.stdout
local pending_open = false
local missing_checker_marker = false

local function local_path(path)
    assert(type(path) == "string" and path:sub(1, #root + 1) == root .. "/",
        "IO escaped native fixture: " .. tostring(path))
    assert(not path:find("/%./") and not path:find("/%.%./") and
        not path:match("/%.%.?$"), "noncanonical fixture path: " .. path)
    return path
end

local function emit(value)
    assert(output:write(JSON.stringify(value), "\n"))
    assert(output:flush())
end

local function receive()
    local line = input:read("*l")
    assert(line, "controller closed native fixture input")
    local value = JSON.parse(line)
    assert(type(value) == "table" and type(value.op) == "string", "invalid fixture request")
    return value
end

local function journal(value)
    local fd = assert(native_open(root .. "/" .. actor .. ".io.jsonl", "ab"))
    assert(fd:write(JSON.stringify(value), "\n"))
    assert(fd:close())
end

local function bridge(command)
    assert(type(command) == "string", "native command must be text")
    -- The bridge validates the shell command, then runs its original IO primitives
    -- with /bin/sh. It does not fabricate mktemp paths, exit markers or IO status.
    return LIB.shell_escape(python) .. " " .. LIB.shell_escape(repo .. "/tests/native_io.py") ..
        " --fixture-command " .. LIB.shell_escape(root) .. " " .. LIB.shell_escape(actor) ..
        " shell " .. LIB.shell_escape(command)
end

io.open = function(path, mode)
    local_path(path)
    local fd, err, errno = native_open(path, mode)
    journal({ operation = "open", path = path, mode = mode or "r", ok = fd ~= nil, errno = errno })
    if fd and pending_open and (mode or "r"):find("w", 1, true) then
        pending_open = false
        emit({ event = "stage-open", path = path })
        -- No synthetic handle: the actual native descriptor remains open here.
        local received, release = pcall(receive)
        if not received or release.op ~= "release" then
            fd:close()
            journal({ operation = "stage-open-aborted", path = path, descriptor_closed = true })
            error(not received and release or "expected native stage-open release")
        end
    end
    return fd, err, errno
end

os.remove = function(path)
    local_path(path)
    local ok, err, errno = native_remove(path)
    journal({ operation = "remove", path = path, ok = ok ~= nil, error = err, errno = errno })
    return ok, err, errno
end

os.rename = function(source, target)
    local_path(source)
    local_path(target)
    local ok, err, errno = native_rename(source, target)
    journal({ operation = "rename", source = source, target = target,
        ok = ok ~= nil, error = err, errno = errno })
    return ok, err, errno
end

io.popen = function(command, mode)
    assert(mode == nil or mode == "r", "native IO fixture allows read-only command pipes")
    if missing_checker_marker and command:find("sing-box check -c ", 1, true) then
        missing_checker_marker = false
        journal({ operation = "checker-transport-missing-marker", original_command = command })
        -- Model a transport that completes without delivering checked evidence.
        -- The native subprocess really produces empty stdout and no PT_EXIT;
        -- production exec_checked, not this fixture, must classify the failure.
        command = ":"
    end
    -- Return the real handle; production owns its read and single close.
    return native_popen(bridge(command), mode or "r")
end

os.execute = function(command)
    return native_execute(bridge(command))
end

package.preload["luci.jsonc"] = function() return JSON end

local SRV = require("podkop-tweaker.services")
for _, name in ipairs({ "stage_file", "publish_file", "discard_stage", "write_file_atomic",
    "with_lock", "exec_checked", "backup_current", "restore_backup", "validate_service", "apply_service" }) do
    assert(type(SRV[name]) == "function", "missing integrated services API: " .. name)
end
assert(SRV.LOCK_ROOT == "/var/lock", "services.LOCK_ROOT must default to /var/lock")
SRV.LOCK_ROOT = root .. "/locks"

local names = { podkop = "podkop.uci", stubby = "stubby.uci", singbox = "singbox.json" }
for name, basename in pairs(names) do
    local svc = assert(SRV[name])
    svc.config = root .. "/live/" .. basename
    svc.backup = svc.config .. ".auto-backup"
    svc.restart_cmd = LIB.shell_escape(root .. "/services/" .. name) .. " restart 2>&1"
    local ops = assert(SRV.ops[name])
    ops.svc = svc
    ops.init = root .. "/services/" .. name
    ops.pid = "native-io-" .. actor .. "-" .. name
end
SRV.SINGBOX_CONFIG, SRV.SINGBOX_BACKUP = SRV.singbox.config, SRV.singbox.backup
SRV.SUBS_FILE, SRV.UPDATE_LOG_FILE = root .. "/subscriptions.json", root .. "/updates.log"

local function service(request)
    assert(names[request.service], "unknown fixture service")
    return SRV[request.service]
end

local function file_result(ok, err, details, kind)
    return { ok = ok, error = err, details = details, kind = kind }
end

local function command_result(command)
    local ok, details, code = SRV.exec_checked(command)
    return { ok = ok, details = details, code = code }
end

local function lock_result(key, hold, nested)
    local entered = false
    local a, b, c = SRV.with_lock(key, function()
        entered = true
        if nested then
            local x, y, z = SRV.with_lock(key, function() return "nested", false, 19 end)
            assert(x == "nested" and y == false and z == 19, "same-owner reentrancy lost return values")
        end
        if hold then
            emit({ event = "lock-held", key = key })
            assert(receive().op == "release", "expected native lock release")
        end
        return "acquired", false, 37
    end)
    return { first = a, second = b, third = c, entered = entered }
end

local function coroutine_owners(key)
    local function owner()
        local entered, foreign_entered = false, false
        local result = SRV.with_lock(key, function()
            entered = true
            local x, y, z = SRV.with_lock(key, function() return "same-owner", false, 23 end)
            assert(x == "same-owner" and y == false and z == 23, "nested coroutine owner was not reentrant")
            local foreign = coroutine.create(function()
                return SRV.with_lock(key, function()
                    foreign_entered = true
                    return "foreign-must-not-enter"
                end)
            end)
            local resumed, value, err = coroutine.resume(foreign)
            assert(resumed, value)
            assert(value == nil and type(err) == "string" and err ~= "", "foreign coroutine was not busy")
            assert(not foreign_entered, "foreign coroutine entered the owner's resource")
            -- A rejected foreign actor must not drop the owner's recursion depth.
            assert(SRV.with_lock(key, function() return "still-owned" end) == "still-owned")
            return "owner-finished"
        end)
        assert(entered and result == "owner-finished", "coroutine owner failed")
    end
    -- Neither owner yields across Lua 5.1 pcall/xpcall. The foreign coroutine is
    -- resumed synchronously while the owner's real mkdir lock is still held.
    owner()
    local thread = coroutine.create(owner)
    local ok, err = coroutine.resume(thread)
    assert(ok and coroutine.status(thread) == "dead", err)
    return { main_and_coroutine = true }
end

local function dispatch(request)
    local op = request.op
    if op == "stage" then
        pending_open = request.pause_open == true
        local path, err = SRV.stage_file(local_path(request.target), request.content, request.options)
        assert(not pending_open, "production stage_file did not reach a real writable open")
        return { path = path, error = err }
    elseif op == "check-stage" then
        return command_result("sing-box check -c " .. LIB.shell_escape(local_path(request.path)))
    elseif op == "publish" then
        return file_result(SRV.publish_file(local_path(request.path), local_path(request.target)))
    elseif op == "discard" then
        SRV.discard_stage(local_path(request.path))
        return { done = true }
    elseif op == "atomic" then
        pending_open = request.pause_open == true
        local ok, err = SRV.write_file_atomic(local_path(request.target), request.content, request.options)
        assert(not pending_open, "production write_file_atomic did not reach a real writable open")
        return file_result(ok, err)
    elseif op == "lock" or op == "hold-lock" then
        return lock_result(request.key, op == "hold-lock", request.nested == true)
    elseif op == "coroutines" then
        return coroutine_owners(request.key)
    elseif op == "exception" then
        local paths = {}
        local ok, err = pcall(function()
            SRV.with_lock(request.key, function()
                paths.published = assert(SRV.stage_file(local_path(request.target), request.content))
                assert(SRV.publish_file(paths.published, request.target))
                paths.pending = assert(SRV.stage_file(local_path(request.pending_target), "pending own bytes"))
                error("native-io-owned-exception")
            end)
        end)
        assert(not ok and tostring(err):find("native-io-owned-exception", 1, true), "lock swallowed callback exception")
        return { caught = true, paths = paths, error = tostring(err) }
    elseif op == "backup" then
        local ok, err, metadata = SRV.backup_current(service(request))
        return { ok = ok, error = err, metadata = metadata }
    elseif op == "restore" then
        return file_result(SRV.restore_backup(service(request)))
    elseif op == "validate" then
        if request.checker_transport ~= nil then
            assert(request.checker_transport == "missing-marker", "unknown checker transport fault")
            missing_checker_marker = true
        end
        local result = file_result(SRV.validate_service(service(request), request.content))
        assert(not missing_checker_marker, "missing-marker fault did not reach the checker transport")
        return result
    elseif op == "apply" then
        return SRV.apply_service(service(request), request.content, { restart = false })
    elseif op == "exec" then
        return command_result(request.command)
    elseif op == "quit" then
        return { bye = true }
    end
    error("unknown native fixture operation: " .. tostring(op))
end

emit({ event = "ready", lua = _VERSION, lock_root = SRV.LOCK_ROOT })
while true do
    local line = input:read("*l")
    if not line then break end
    local request = JSON.parse(line)
    local ok, result = xpcall(function()
        assert(type(request) == "table" and type(request.op) == "string", "invalid fixture request")
        return dispatch(request)
    end, debug.traceback)
    pending_open = false
    missing_checker_marker = false
    if ok then
        emit({ event = "result", result = result })
    else
        emit({ event = "error", error = tostring(result) })
    end
    if request and request.op == "quit" then break end
end
