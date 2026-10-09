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

function M.run(id, target, fn)
    local tracked = id ~= nil and id ~= ""
    local record
    if tracked then
        if not M.valid_id(id) then return { error = "Invalid restart operation ID" } end
        local instance = M.instance()
        if not instance then return { error = "Cannot identify the web server process" } end
        local previous = read_record()
        if previous and (previous.id == id or previous.state == "working" or
            previous.state == "applied" and previous.previous_instance == instance) then
            return { error = "A web restart operation is already pending" }
        end
        record = { id = id, target = target, state = "working", started = os.time(), previous_instance = instance }
        local written, err = store(record)
        if not written then return { error = "Cannot create restart state", details = err } end
    end

    local called, response = pcall(fn)
    if not called or type(response) ~= "table" then response = { error = "Internal error" } end
    if record then
        record.state = response.success == true and "applied" or "failed"
        record.expected_version = response.new_version
        record.error = response.error and tostring(response.error):sub(1, 2048) or nil
        local written, err = store(record)
        if not written then return { success = false, applied = response.success == true, error = "Cannot record operation result", details = err } end
        response.restart_id = id
    end
    if response.success == true then
        local queued, output = queue_restart()
        if not queued then
            if record then record.state, record.error = "failed", "Applied, but web restart could not be scheduled"; store(record) end
            return { success = false, applied = true, error = "Applied, but web restart could not be scheduled",
                details = output ~= "" and output or "Restart launcher returned no status output", restart_id = tracked and id or nil }
        end
    end
    return response
end

function M.status(id)
    if not M.valid_id(id) then return { error = "Invalid restart operation ID" } end
    local record = read_record()
    if not record or record.id ~= id then return { error = "No matching recent restart operation" } end
    local instance = M.instance()
    return { id = id, target = record.target, state = record.state, expected_version = record.expected_version,
        error = record.error, restarted = record.state == "applied" and instance ~= nil and instance ~= record.previous_instance }
end

return M
