-- Detached Argon theme worker regressions (4.11.0 stage C): admission
-- reservation, the single queued->running claim, terminal evidence and the
-- read-only supervision view.
package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path
local H = require("pt_harness")
local ID, ID2 = string.rep("a", 32), string.rep("b", 32)
local JOB_FILE = "/tmp/pt-argon-theme-job.json"
local RECORD = "/tmp/pt-web-restart.json"
local WEB_LOCK = "/var/lock/podkop-tweaker-web-update.lock"

local function begin(opts)
    H.begin(opts)
    H.vfs_write("/proc/stat", "btime 5000\n")
    local WORKER = require("podkop-tweaker.theme_worker")
    return WORKER
end

local function write_job(worker, job)
    H.vfs_write(JOB_FILE, H.json.stringify(job))
    return job
end

after_each(function() H.finish() end)

describe("theme job admission", function()
    it("registers a queued job and spawns the detached worker", function()
        local W = begin()
        local response = W.admit(ID)
        assert.is_true(response.success)
        assert.is_true(response.queued)
        assert.equal(ID, response.restart_id)
        assert.equal(1, H.state().forks)
        local job = W.read_job()
        assert.equal("queued", job.state)
        assert.equal(ID, job.id)
    end)

    it("rejects invalid IDs without registering or spawning anything", function()
        local W = begin()
        for _, bad in ipairs({ "../x", "", "short" }) do
            local response = W.admit(bad)
            assert.is_false(response.success)
            assert.truthy(response.error)
        end
        assert.is_nil(H.state().forks)
        assert.falsy(H.vfs_exists(JOB_FILE))
    end)

    it("refuses admission while a fresh queued job holds the reservation", function()
        local W = begin()
        assert.is_true(W.admit(ID).success)
        local response = W.admit(ID2)
        assert.is_false(response.success)
        assert.matches("already starting", response.error)
        assert.equal(ID, W.read_job().id)
        assert.equal(1, H.state().forks)
    end)

    it("refuses admission while a live worker holds the reservation", function()
        local W = begin()
        write_job(W, { schema = 1, id = ID, state = "running", created = os.time() - 5,
            started = os.time() - 4, worker_pid = 4242, worker_start = 700 })
        local response = W.admit(ID2)
        assert.is_false(response.success)
        assert.matches("already running", response.error)
        assert.equal("running", W.read_job().state)
    end)

    it("treats a running job with an unreadable worker identity as reserved", function()
        local W = begin()
        H.state().failures["/proc/4555/stat"] = { open = true }
        write_job(W, { schema = 1, id = ID, state = "running", created = os.time() - 5,
            started = os.time() - 4, worker_pid = 4555, worker_start = 9 })
        local response = W.admit(ID2)
        assert.is_false(response.success)
        assert.matches("uncertain", response.error)
    end)

    it("replaces an expired unstarted job and records it as start-unconfirmed history", function()
        local W = begin()
        write_job(W, { schema = 1, id = ID, state = "queued", created = os.time() - (W.STARTUP_DEADLINE + 5) })
        local response = W.admit(ID2)
        assert.is_true(response.success)
        local job = W.read_job()
        assert.equal(ID2, job.id)
        assert.equal(1, #job.history)
        assert.equal(ID, job.history[1].id)
        assert.is_true(job.history[1].start_unconfirmed)
    end)

    it("replaces an interrupted job with a dead worker and preserves its unknown facts", function()
        local W = begin()
        write_job(W, { schema = 1, id = ID, state = "running", created = os.time() - 60,
            started = os.time() - 59, worker_pid = 39999, worker_start = 42,
            result = { success = false, unknown = true, error = "partial diagnostics" } })
        local response = W.admit(ID2)
        assert.is_true(response.success)
        local history = W.read_job().history
        assert.equal(1, #history)
        assert.equal(ID, history[1].id)
        assert.is_true(history[1].interrupted)
        assert.is_true(history[1].unknown)
        assert.equal("partial diagnostics", history[1].error)
    end)

    it("reports a spawn failure as an explicit terminal job without a worker", function()
        local W = begin()
        H.state().fork_fail = true
        local response = W.admit(ID)
        assert.is_false(response.success)
        assert.matches("Cannot start the theme worker", response.error)
        local job = W.read_job()
        assert.equal("failed", job.state)
        assert.matches("fork failed", job.result.details)
    end)
end)

describe("theme worker claim and execution", function()
    local function stub_pipeline(result)
        local THEME = require("podkop-tweaker.theme")
        THEME.run_pipeline = result or function()
            return { success = true, new_version = "3.0.0-r2" }
        end
    end

    it("claims a queued job exactly once and finalizes terminal evidence", function()
        local W = begin({ sys = { { match = "pidof uhttpd", out = "100\n" } } })
        H.vfs_write("/proc/100/stat", "100 (uhttpd) S " .. string.rep("0 ", 18) .. "1000\n")
        stub_pipeline()
        write_job(W, { schema = 1, id = ID, state = "queued", created = os.time() })
        assert.equal(0, W.run(ID))
        local job = W.read_job()
        assert.equal("completed", job.state)
        assert.equal("3.0.0-r2", job.result.new_version)
        assert.is_true(job.restart.queued)
        local record = H.json.parse(H.vfs_read(RECORD))
        assert.equal(ID, record.id)
        assert.equal("theme", record.target)
        assert.equal("applied", record.state)
        assert.falsy(H.vfs_exists(WEB_LOCK))
    end)

    it("keeps a failed pipeline terminal without restart evidence", function()
        local W = begin()
        stub_pipeline(function() return { success = false, error = "APK failed", phase = "theme", partial = true } end)
        write_job(W, { schema = 1, id = ID, state = "queued", created = os.time() })
        assert.equal(0, W.run(ID))
        local job = W.read_job()
        assert.equal("failed", job.state)
        assert.equal("APK failed", job.result.error)
        assert.is_nil(job.restart)
        assert.falsy(H.vfs_exists(RECORD))
    end)

    it("never lets a second worker claim the same job generation", function()
        local W = begin()
        local runs = 0
        stub_pipeline(function() runs = runs + 1; return { success = true, new_version = "x" } end)
        write_job(W, { schema = 1, id = ID, state = "queued", created = os.time() })
        W.run(ID)
        assert.equal(3, W.run(ID))
        assert.equal(1, runs)
        assert.equal("completed", W.read_job().state)
    end)

    it("exits quietly when the job was replaced by another admission", function()
        local W = begin()
        local runs = 0
        stub_pipeline(function() runs = runs + 1; return { success = true } end)
        write_job(W, { schema = 1, id = ID2, state = "queued", created = os.time() })
        assert.equal(3, W.run(ID))
        assert.equal(0, runs)
        assert.equal("queued", W.read_job().state)
    end)

    it("marks an interrupted exception terminal with unknown facts and no replay", function()
        local W = begin()
        stub_pipeline(function() error("worker crashed mid-APK") end)
        write_job(W, { schema = 1, id = ID, state = "queued", created = os.time() })
        assert.equal(4, W.run(ID))
        local job = W.read_job()
        assert.equal("failed", job.state)
        assert.is_true(job.result.unknown)
        assert.matches("interrupted", job.result.error)
        assert.falsy(H.vfs_exists(RECORD))
    end)

    it("marks an unstartable worker terminal when the reservation is unavailable", function()
        local W = begin()
        local runs = 0
        stub_pipeline(function() runs = runs + 1; return { success = true } end)
        H.vfs_mkdir(WEB_LOCK)
        H.vfs_write(WEB_LOCK .. "/owner", "another invocation")
        write_job(W, { schema = 1, id = ID, state = "queued", created = os.time() })
        assert.equal(3, W.run(ID))
        assert.equal(0, runs)
        local job = W.read_job()
        assert.equal("failed", job.state)
        assert.matches("Cannot acquire web update lock", job.result.error)
    end)
end)

describe("theme job supervision", function()
    it("reports a fresh queued job as starting", function()
        local W = begin()
        write_job(W, { schema = 1, id = ID, state = "queued", created = os.time() })
        local status = W.status(ID)
        assert.equal("queued", status.state)
        assert.is_nil(status.interrupted)
    end)

    it("presents an expired queued job as failed start-unconfirmed without rewriting it", function()
        local W = begin()
        write_job(W, { schema = 1, id = ID, state = "queued", created = os.time() - (W.STARTUP_DEADLINE + 1) })
        local status = W.status(ID)
        assert.equal("failed", status.state)
        assert.is_true(status.start_unconfirmed)
        assert.equal("queued", W.read_job().state, "supervision must stay read-only")
    end)

    it("presents a running job with a dead worker as interrupted, not failed", function()
        local W = begin()
        write_job(W, { schema = 1, id = ID, state = "running", created = os.time() - 5,
            started = os.time() - 4, worker_pid = 39999, worker_start = 8 })
        local status = W.status(ID)
        assert.equal("running", status.state)
        assert.is_true(status.interrupted)
        assert.is_true(status.result.unknown)
    end)

    it("answers for a superseded job from bounded history", function()
        local W = begin()
        write_job(W, { schema = 1, id = ID2, state = "queued", created = os.time(),
            history = { { id = ID, state = "failed", error = "prior diagnostics", unknown = true } } })
        local status = W.status(ID)
        assert.is_true(status.superseded)
        assert.equal(ID2, status.superseded_by)
        assert.equal("failed", status.state)
        assert.equal("prior diagnostics", status.error)
        assert.is_true(status.unknown)
    end)

    it("rejects unknown or malformed identifiers and absent jobs", function()
        local W = begin()
        assert.truthy(W.status("nope").error)
        assert.truthy(W.status(ID).error)
        H.vfs_write(JOB_FILE, "{not json")
        assert.truthy(W.status(ID).error)
    end)

    it("reserves all web-update mutations while the job is active", function()
        local W = begin()
        write_job(W, { schema = 1, id = ID, state = "running", created = os.time() - 5,
            started = os.time() - 4, worker_pid = 4242, worker_start = 700 })
        local WEB = require("podkop-tweaker.web_restart")
        local mutations = 0
        for _, target in ipairs({ "cache", "tweaker" }) do
            local response = WEB.run(ID2, target, function() mutations = mutations + 1; return { success = true } end)
            assert.truthy(response.error)
            assert.matches("theme update is in progress", response.error)
        end
        assert.equal(0, mutations)
        assert.falsy(H.vfs_exists(RECORD))
    end)
end)
