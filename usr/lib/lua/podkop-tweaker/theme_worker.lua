-- Detached Argon theme update worker (4.11.0 train, stage C).
-- CLI: lua /usr/lib/lua/podkop-tweaker/theme_worker.lua <job-id>
-- A queued/running job reserves the web-update resource; the worker claims the
-- admitted generation exactly once (queued -> running), runs the theme
-- pipeline under that reservation and finalizes bounded job evidence plus the
-- restart record with a fresh pre-restart uhttpd baseline.
local SRV = require("podkop-tweaker.services")
local WEB = require("podkop-tweaker.web_restart")
local S = require("pt-subs-lib")
local M = {}
M.JOB_FILE = "/tmp/pt-argon-theme-job.json"
M.JOB_LIMIT = 65536
M.RESULT_DETAILS_LIMIT = 60000
M.STARTUP_DEADLINE = 30
M.HISTORY_ENTRIES = 4

local function valid_state(state)
    return state == "queued" or state == "running" or state == "completed" or state == "failed"
end

local function worker_alive(job)
    if type(job.worker_pid) ~= "number" or type(job.worker_start) ~= "number" then return nil end
    local start, errno = SRV.proc_start_time(job.worker_pid)
    if start == false then return nil end -- malformed identity: unknown
    if start == nil then
        if errno == 2 then return false end
        return nil
    end
    return start == job.worker_start -- mismatch means the pid was reused: dead
end

function M.read_job()
    local raw, err, errno = SRV.read_file(M.JOB_FILE, M.JOB_LIMIT)
    if not raw then
        if errno == 2 then return nil end
        return nil, err or "Cannot read theme job state"
    end
    local job = S.json_parse(raw)
    if type(job) ~= "table" or job.schema ~= 1 or not WEB.valid_id(job.id) or not valid_state(job.state)
        or type(job.created) ~= "number" or (job.started ~= nil and type(job.started) ~= "number")
        or (job.worker_pid ~= nil and type(job.worker_pid) ~= "number")
        or (job.worker_start ~= nil and type(job.worker_start) ~= "number")
        or (job.history ~= nil and type(job.history) ~= "table") then
        return nil, "Invalid theme job state"
    end
    return job
end

function M.write_job(job)
    job.updated = os.time()
    local raw = S.json_stringify(job)
    if not raw or #raw > M.JOB_LIMIT then return false, "Theme job state exceeds size limit" end
    return SRV.write_file_atomic(M.JOB_FILE, raw, { mode = "600", suffix = ".tmp-job" })
end

-- Unlocked supervision view. Returns the job table only while it reserves the
-- web-update slot: queued within the startup deadline, running with a live or
-- unverifiable worker. Expired/interrupted/terminal jobs are not reservations.
function M.active_job()
    local job, err = M.read_job()
    if not job then return nil, err end
    if job.state == "queued" then
        if os.time() - job.created > M.STARTUP_DEADLINE then return nil end
        return job
    end
    if job.state == "running" then
        if worker_alive(job) == false then return nil end
        return job
    end
    return nil
end

local function bounded_result(result)
    if type(result) ~= "table" then return { success = false, error = "Invalid worker result" } end
    local bounded = {}
    for key, value in pairs(result) do bounded[key] = value end
    if type(bounded.details) == "string" and #bounded.details > M.RESULT_DETAILS_LIMIT then
        bounded.details = bounded.details:sub(1, M.RESULT_DETAILS_LIMIT)
        bounded.details_truncated = true
    end
    return bounded
end

local function history_entry(job, now)
    local entry = { id = job.id, state = job.state }
    if type(job.result) == "table" then
        entry.error = job.result.error
        entry.resume_available = job.result.resume_available == true or nil
        entry.unknown = job.result.unknown == true or nil
    end
    if job.state == "running" then entry.interrupted = true end
    if job.state == "queued" and now - job.created > M.STARTUP_DEADLINE then entry.start_unconfirmed = true end
    return entry
end

-- Short admission under the web-update reservation: register the job, then
-- spawn the detached worker. Admission is not application and not proof of a
-- running worker; an unstarted job expires after STARTUP_DEADLINE seconds and
-- requires an explicit new Start.
function M.admit(id)
    if not WEB.valid_id(id) then return { success = false, error = "Invalid restart operation ID" } end
    local n = SRV.nixio_module()
    if not n then return { success = false, error = "Cannot start the theme worker on this system" } end
    local ok, response, lock_err = pcall(SRV.with_lock, "web-update", function()
        local job, jerr = M.read_job()
        if not job and jerr then return { success = false, error = jerr } end
        local now = os.time()
        if job then
            if job.state == "queued" and now - job.created <= M.STARTUP_DEADLINE then
                return { success = false, error = "A theme update is already starting" }
            end
            if job.state == "running" then
                local alive = worker_alive(job)
                if alive ~= false then
                    return { success = false, error = alive == nil and
                        "Theme update status is uncertain; retry later" or "A theme update is already running" }
                end
            end
        end
        local history = type(job) == "table" and type(job.history) == "table" and job.history or {}
        if job then
            history[#history + 1] = history_entry(job, now)
            while #history > M.HISTORY_ENTRIES do table.remove(history, 1) end
        end
        local fresh = { schema = 1, id = id, state = "queued", created = now, history = history }
        local written, werr = M.write_job(fresh)
        if not written then return { success = false, error = "Cannot register theme job", details = werr } end
        local pid, perr = M.spawn(n, id)
        if not pid then
            fresh.state = "failed"
            fresh.result = { success = false, error = "Cannot start the theme worker", details = perr }
            M.write_job(fresh)
            return { success = false, error = "Cannot start the theme worker", details = perr }
        end
        return { success = true, queued = true, restart_id = id }
    end)
    if not ok then
        return { success = false, error = "Cannot coordinate theme job admission", details = tostring(response) }
    end
    if type(response) == "table" then return response end
    return { success = false, error = lock_err or "Cannot acquire web update lock" }
end

-- Spawn a fresh detached process. The child performs no Lua-side lock or
-- stage continuation: after fork it only calls native nixio primitives and
-- execs the CLI worker, so no forked copy of this Lua state inherits
-- ownership. A missing native capability is an explicit refusal, never a
-- synchronous fallback.
function M.spawn(n, job_id)
    local forked, pid = pcall(n.fork)
    if not forked or type(pid) ~= "number" or pid < 0 then return nil, "fork failed" end
    if pid == 0 then
        if not pcall(function() return n.setsid() end) then os.exit(126) end
        local opened, devnull = pcall(function() return n.open("/dev/null", "r+") end)
        if opened and devnull then
            pcall(function() n.dup(devnull, n.stdin) end)
            pcall(function() n.dup(devnull, n.stdout) end)
            pcall(function() n.dup(devnull, n.stderr) end)
        end
        pcall(function() n.exec("/usr/bin/lua", "/usr/lib/lua/podkop-tweaker/theme_worker.lua", job_id) end)
        os.exit(127)
    end
    return pid
end

local function claim(job_id)
    local n = SRV.nixio_module()
    local job, err = M.read_job()
    if not job then return nil, err or "No matching theme job" end
    if job.id ~= job_id then return nil, "Theme job was replaced" end
    if job.state ~= "queued" then return nil, "Theme job is not queued" end -- terminal or already claimed once
    local start = SRV.proc_start_time(n.getpid())
    job.state = "running"
    job.started = os.time()
    job.worker_pid = n.getpid()
    job.worker_start = start
    local written, werr = M.write_job(job)
    if not written then return nil, "Cannot claim theme job: " .. tostring(werr) end
    return job
end

-- One worker run. Holds web-update for the whole pipeline (the same exclusion
-- the synchronous implementation had), finalizes the job record inside the
-- reservation and, on success, records restart evidence with a fresh
-- pre-restart baseline before the delayed restart.
function M.run(job_id)
    local THEME = require("podkop-tweaker.theme")
    local exit_code = 0
    local finished = false
    local ok, err = pcall(SRV.with_lock, "web-update", function()
        local job, jerr = claim(job_id)
        if not job then
            if jerr then exit_code = 3 end
            return
        end
        local result = THEME.run_pipeline()
        job.state = result and result.success == true and "completed" or "failed"
        job.result = bounded_result(result)
        if job.state == "completed" then
            local record, rerr, rdet = WEB.finalize_restart(job_id, "theme", result)
            job.restart = record and { queued = record.restart_queued == true } or
                { queued = false, error = rerr, details = rdet }
        end
        M.write_job(job)
        finished = true
    end)
    if finished then return exit_code end
    if ok == false then
        -- The exception already crossed with_lock (owned stages cleaned). Mark
        -- the interrupted job under a fresh short reservation; the persistent
        -- recovery state keeps its own resume facts.
        pcall(function()
            SRV.with_lock("web-update", function()
                local job = M.read_job()
                if job and job.id == job_id and job.state == "running" then
                    job.state = "failed"
                    job.result = { success = false, unknown = true,
                        error = "Theme worker was interrupted", details = tostring(err) }
                    M.write_job(job)
                end
            end)
        end)
        return 4
    end
    -- Acquisition failure: the job never started. A fresh queued job is itself
    -- the reservation, so admission will not replace it concurrently.
    local job = M.read_job()
    if job and job.id == job_id and job.state == "queued" then
        job.state = "failed"
        job.result = { success = false, error = "Cannot acquire web update lock", details = tostring(err) }
        M.write_job(job)
    end
    return 3
end

-- Read-only supervision. Never repairs the job file, never restarts anything
-- and never manufactures completion.
function M.status(id)
    if not WEB.valid_id(id) then return { error = "Invalid theme job ID" } end
    local job, err = M.read_job()
    if not job then return { error = err or "No matching theme job" } end
    if job.id ~= id then
        local history = type(job.history) == "table" and job.history or {}
        for _, entry in ipairs(history) do
            if type(entry) == "table" and entry.id == id then
                return { id = id, state = entry.state, superseded = true, superseded_by = job.id,
                    error = entry.error, unknown = entry.unknown == true or nil }
            end
        end
        return { error = "No matching theme job" }
    end
    local response = { id = id, state = job.state, created = job.created, started = job.started,
        updated = job.updated, restart = job.restart }
    if job.state == "queued" then
        if os.time() - job.created > M.STARTUP_DEADLINE then
            response.state = "failed"
            response.start_unconfirmed = true
            response.result = { success = false, error = "Theme worker did not start" }
        end
    elseif job.state == "running" then
        if worker_alive(job) == false then
            response.interrupted = true
            response.result = { success = false, unknown = true, error = "Theme worker was interrupted" }
        end
    else
        response.result = job.result
        if type(job.result) == "table" and job.result.resume_available == true then
            response.resume_available = true
        end
    end
    return response
end

local cli_params = { ... }
if type(cli_params[1]) == "string" and WEB.valid_id(cli_params[1]) and cli_params[2] == nil
    and (arg == nil or tostring(arg and arg[0] or ""):find("theme_worker", 1, true)) then
    os.exit(M.run(cli_params[1]))
end

return M
