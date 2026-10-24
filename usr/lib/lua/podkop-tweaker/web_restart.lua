-- One bounded, private RAM record ties an apply result to a new uhttpd process.
local M = {}
local SRV = require("podkop-tweaker.services")
local S = require("pt-subs-lib")
local LIB = require("podkop-tweaker.lib")
local RECORD = "/tmp/pt-web-restart.json"
local TTL = 900

function M.valid_id(id)
    return type(id) == "string" and #id == 32 and id:match("^[a-f0-9]+$") ~= nil
end

function M.instance()
    local raw = require("luci.sys").exec("pidof uhttpd 2>/dev/null") or ""
    local pid
    for value in raw:gmatch("%d+") do
        local n = tonumber(value)
        if n > 0 and n <= 2147483647 and (not pid or n < pid) then pid = n end
    end
    if not pid then return nil end
    local stat = SRV.read_file("/proc/" .. pid .. "/stat", 4096)
    local fields = stat and stat:match("^%d+ %b() (.+)$")
    if not fields then return nil end
    local index = 0
    for field in fields:gmatch("%S+") do
        index = index + 1
        if index == 20 and field:match("^%d+$") then return pid .. ":" .. field end
    end
    return nil
end

local function read_record()
    local record = S.json_parse(SRV.read_file(RECORD, 8192))
    if type(record) ~= "table" or not M.valid_id(record.id) or type(record.started) ~= "number"
        or os.time() - record.started < 0 or os.time() - record.started > TTL then return nil end
    if record.target ~= "tweaker" and record.target ~= "theme" and record.target ~= "cache" then return nil end
    if record.state ~= "working" and record.state ~= "applied" and record.state ~= "failed" then return nil end
    if type(record.previous_instance) ~= "string" or not record.previous_instance:match("^%d+:%d+$") then return nil end
    if record.restart_queued ~= nil and type(record.restart_queued) ~= "boolean" then return nil end
    if record.unknown ~= nil and type(record.unknown) ~= "boolean" then return nil end
    if record.supersedes ~= nil and not M.valid_id(record.supersedes) then return nil end
    return record
end

local function store(record)
    local text = S.json_stringify(record)
    if not text or #text > 8192 then return false, "Cannot serialize restart state" end
    return SRV.write_file_atomic(RECORD, text, { mode = "600" })
end

local function queue_restart()
    -- Give the dispatcher time to send its JSON response before losing the socket.
    local command = SRV.background_command("/etc/init.d/uhttpd restart", 1)
    local status, kind, code = os.execute(command)
    local details = "Launcher exit status: " .. tostring(status) .. "; kind: " .. tostring(kind) .. "; code: " .. tostring(code)
    return LIB.exit_ok(status, kind, code), details
end

local function append_details(original, extra)
    if not extra or extra == "" then return original end
    if not original or original == "" then return extra end
    return original .. "\n" .. extra
end

local function failed_result(completed, message, details, unknown)
    local result = {}
    for key, value in pairs(completed or {}) do result[key] = value end
    -- Entering a callback or failing to release a lock is not apply evidence.
    result.applied = completed ~= nil and (completed.success == true or completed.applied == true)
    result.success = false
    result.unknown = result.unknown == true or unknown == true
    if result.error then
        result.details = append_details(result.details, append_details(message, details))
    else
        result.error = message
        result.details = append_details(result.details, details)
    end
    return result
end

function M.run(id, target, fn)
    local tracked = id ~= nil and id ~= ""
    if tracked and not M.valid_id(id) then return { error = "Invalid restart operation ID" } end
    local record, completed, mutation_started
    -- Evidence is for read-only recovery, not mutual exclusion. Include legacy
    -- callers without an ID in the same interprocess mutation lock.
    local function run_locked()
        -- A queued or running theme job reserves the whole web-update resource
        -- for its worker: admission and Local/Git/cache mutations share one slot.
        local active = require("podkop-tweaker.theme_worker").active_job()
        if active then return { error = "A theme update is in progress" } end
        if tracked then
            local instance = M.instance()
            if not instance then return { error = "Cannot identify the web server process" } end
            local previous = read_record()
            if previous and (previous.id == id or previous.state == "working" or
                previous.state == "applied" and previous.previous_instance == instance) then
                return { error = "A web restart operation is already pending" }
            end
            record = { id = id, target = target, state = "working", started = os.time(),
                previous_instance = instance, restart_queued = false,
                supersedes = previous and previous.id ~= id and previous.id or nil }
            local written, err = store(record)
            if not written then return { error = "Cannot create restart state", details = err } end
        end

        mutation_started = true
        -- Let exceptions cross with_lock so it cleans this invocation's stages
        -- before the outer pcall converts the result into read-only uncertainty.
        -- The own record keeps its working state and gains the error trail: a
        -- rejected competing request never touches this evidence.
        local ok_call, called = pcall(fn)
        if not ok_call then
            if record then
                record.error = tostring(called):sub(1, 2048)
                record.unknown = true
                pcall(store, record)
            end
            error(called, 0)
        end
        local result = called
        if type(result) ~= "table" then
            if record then
                record.error = "Invalid web operation result"
                record.unknown = true
                pcall(store, record)
            end
            error("Invalid web operation result")
        end
        if result.success == true and (result.error ~= nil or result.partial == true or result.unknown == true) then
            result.success = false
            result.error = result.error or "Operation did not complete successfully"
        end
        completed = result
        if record then
            result.restart_id = id
            record.state = result.unknown == true and "working" or result.success == true and "applied" or "failed"
            record.expected_version = result.new_version
            record.error = result.error and tostring(result.error):sub(1, 2048) or nil
            local written, err = store(record)
            if not written then
                return failed_result(result, "Cannot record operation result", err, true)
            end
        end
        if result.success == true then
            local queued, output = queue_restart()
            if not queued then
                local details = output ~= "" and output or "Restart launcher returned no status output"
                local unknown = false
                if record then
                    record.state, record.error = "failed", "Applied, but web restart could not be scheduled"
                    local written, err = store(record)
                    if not written then
                        details = details .. "\nCannot record restart failure: " .. tostring(err)
                        unknown = true
                    end
                end
                return failed_result(result, "Applied, but web restart could not be scheduled", details, unknown)
            end
            if record then
                record.restart_queued = true
                local written, err = store(record)
                if not written then
                    return failed_result(result, "Cannot record web restart scheduling result", err, true)
                end
            end
        end
        return result
    end
    local called, response, lock_err, uncertain = pcall(SRV.with_lock, "web-update", function()
        completed = run_locked()
        return completed
    end)
    if called and type(response) == "table" then return response end

    local unknown = mutation_started == true or uncertain == true
    local message = unknown and "Web operation result is unknown; update coordination did not finish" or "Cannot acquire web update lock"
    local details = called and lock_err or response
    local result = failed_result(completed, message, tostring(details or "Web update lock returned no result"), unknown)
    if called then
        if result.lock_error then result.web_lock_error = lock_err
        else result.lock_error = lock_err end
    end
    if record then result.restart_id = id end
    return result
end

function M.status(id)
    if not M.valid_id(id) then return { error = "Invalid restart operation ID" } end
    local record = read_record()
    if not record or record.id ~= id then return { error = "No matching recent restart operation" } end
    local instance = M.instance()
    return { id = id, target = record.target, state = record.state, expected_version = record.expected_version,
        error = record.error, restarted = record.state == "applied" and record.restart_queued ~= false and
            instance ~= nil and instance ~= record.previous_instance }
end

-- Terminal evidence for an already-running detached worker. The caller owns
-- the web-update resource (reentrant acquisition) and supplies the completed
-- pipeline result. Unlike M.run, the uhttpd baseline is captured fresh at the
-- end of the pipeline, right before the restart is queued, so a web restart
-- that happened during a long update cannot make verification impossible.
function M.finalize_restart(id, target, result)
    if not M.valid_id(id) then return nil, "Invalid restart operation ID" end
    if type(result) ~= "table" then return nil, "Invalid operation result" end
    local instance = M.instance()
    if not instance then return nil, "Cannot identify the web server process" end
    local previous = read_record()
    local record = { id = id, target = target,
        state = result.success == true and "applied" or "failed",
        started = os.time(), previous_instance = instance, restart_queued = false,
        expected_version = result.new_version,
        error = result.error and tostring(result.error):sub(1, 2048) or nil,
        unknown = result.unknown == true or nil,
        supersedes = previous and previous.id ~= id and previous.id or nil }
    local written, err = store(record)
    if not written then return nil, "Cannot record operation result", err end
    if result.success ~= true then return record end
    local queued, output = queue_restart()
    if queued then
        record.restart_queued = true
        local stored, store_err = store(record)
        if not stored then return nil, "Cannot record web restart scheduling result", store_err end
        return record
    end
    record.state, record.error = "failed", "Applied, but web restart could not be scheduled"
    pcall(store, record)
    return nil, "Applied, but web restart could not be scheduled", output
end

return M
