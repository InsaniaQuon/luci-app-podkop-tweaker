package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path
local H = require("pt_harness")
local ID = string.rep("a", 32)
local RECORD = "/tmp/pt-web-restart.json"
local LOCK = "/var/lock/podkop-tweaker-web-update.lock"
local STAGES = RECORD .. ".tmp-write.*"
local function stat(start)
    return "100 (uhttpd) S " .. string.rep("0 ", 18) .. start .. "\n"
end
local function begin(opts)
    opts = opts or {}
    opts.strict = true
    opts.sys = opts.sys or { { match = "pidof uhttpd", out = "101 100\n" } }
    opts.execute = opts.execute or {}
    opts.execute[#opts.execute + 1] = { match = "uhttpd restart", out = 0 }
    H.begin(opts)
    H.vfs_write("/proc/100/stat", stat("1000"))
    local U = require("podkop-tweaker.api_update")
    U.init("4.9.0")
    return require("podkop-tweaker.web_restart"), U
end
local function restarted()
    -- Same PID with a new kernel start time must count as a different instance.
    H.vfs_write("/proc/100/stat", stat("2000"))
end
local function assert_no_restart()
    for _, commands in ipairs({ H.exec_cmds(), H.execute_cmds() }) do
        for _, command in ipairs(commands) do assert.falsy(command:find("uhttpd restart", 1, true)) end
    end
end
after_each(function() H.finish() end)

describe("web restart operation evidence", function()
    it("requires successful apply, a new process and the installed version, even for reinstall", function()
        local W, U = begin()
        local r = W.run(ID, "tweaker", function() return { success = true, new_version = "4.9.0", reinstalled = true } end)
        assert.equal(ID, r.restart_id)
        assert.is_false(U.restart_status(ID).ready)
        restarted()
        assert.is_true(U.restart_status(ID).ready)
        U.init("4.8.1")
        assert.is_false(U.restart_status(ID).ready)
        assert.truthy(H.vfs_exists(RECORD))
        assert.equal("600", H.vfs_mode(RECORD))
        local stages = H.allocations(STAGES)
        assert.is_true(#stages >= 2)
        local seen = {}
        for _, allocation in ipairs(stages) do
            assert.equal("600", allocation.mode)
            assert.is_nil(seen[allocation.path])
            seen[allocation.path] = true
            assert.falsy(H.vfs_exists(allocation.path))
        end
        assert.falsy(H.vfs_exists(LOCK))
    end)

    it("cannot turn a failed or partial apply into success by observing a changed version/process", function()
        local W, U = begin()
        local r = W.run(ID, "tweaker", function() return { success = false, error = "Copy failed", files_copied = 1 } end)
        assert.is_false(r.success)
        restarted()
        local status = U.restart_status(ID)
        assert.equal("failed", status.state)
        assert.equal("Copy failed", status.error)
        assert.is_false(status.ready)
        assert_no_restart()
    end)

    it("checks tracking IO and ID before invoking mutation, and rejects duplicate submissions", function()
        local W = begin({ execute = { { match = "chmod 600", out = 1 } } })
        local called = false
        assert.truthy(W.run(ID, "cache", function() called = true; return { success = true } end).error)
        assert.is_false(called)
        H.finish()
        W = begin()
        assert.truthy(W.run("../bad", "cache", function() called = true end).error)
        assert.is_false(called)
        assert.is_true(W.run(ID, "cache", function() return { success = true } end).success)
        assert.truthy(W.run(ID, "cache", function() called = true end).error)
        assert.is_false(called)
    end)

    it("does not accept other IDs, expired, oversized or malformed evidence", function()
        local W, U = begin()
        W.run(ID, "cache", function() return { success = true } end)
        assert.truthy(U.restart_status(string.rep("b", 32)).error)
        local record = H.json.parse(H.vfs_read(RECORD))
        record.started = os.time() - 1000
        H.vfs_write(RECORD, H.json.stringify(record))
        assert.truthy(U.restart_status(ID).error)
        H.vfs_write(RECORD, string.rep("x", 9000))
        assert.truthy(U.restart_status(ID).error)
        H.vfs_write(RECORD, "null")
        assert.truthy(U.restart_status(ID).error)
    end)

    it("recovers a checked result after response loss and permits the next operation only after restart", function()
        local W, U = begin()
        W.run(ID, "cache", function() return { success = true } end)
        local called = false
        assert.truthy(W.run(string.rep("b", 32), "cache", function() called = true end).error)
        assert.is_false(called)
        restarted()
        assert.is_true(U.restart_status(ID).ready)
        assert.is_true(W.run(string.rep("b", 32), "cache", function() return { success = true } end).success)
    end)

    it("reports scheduling failure and never confirms a restart that did not happen", function()
        local W, U = begin({ execute = { { match = "sh -c", out = 256 } } })
        local r = W.run(ID, "cache", function() return { success = true } end)
        assert.is_false(r.success)
        assert.is_true(r.applied)
        assert.matches("Launcher exit status: 256", r.details)
        assert.equal("failed", U.restart_status(ID).state)
        assert.is_false(U.restart_status(ID).ready)
    end)

    it("does not infer launch failure from a missing or unparseable stdout marker", function()
        local W = begin({ sys = { { match = "pidof uhttpd", out = "100" }, { match = "sh -c", out = "launcher error text" } } })
        local r = W.run(ID, "cache", function() return { success = true } end)
        assert.is_true(r.success)
        for _, command in ipairs(H.exec_cmds()) do
            assert.falsy(command:find("sh -c", 1, true), "launcher must use the direct process exit status")
        end
    end)

    it("never confirms a theme operation with no expected or installed version", function()
        local W, U = begin()
        require("podkop-tweaker.theme").installed_version = function() return nil end
        W.run(ID, "theme", function() return { success = true } end)
        restarted()
        assert.is_false(U.restart_status(ID).ready)
    end)

    it("never confirms an empty version as an installed target", function()
        local W, U = begin()
        require("podkop-tweaker.theme").installed_version = function() return "" end
        W.run(ID, "theme", function() return { success = true, new_version = "" } end)
        restarted()
        assert.is_false(U.restart_status(ID).ready)
    end)

    it("retains uncertain evidence and does not restart after a final result-write failure", function()
        local W, U = begin()
        local r = W.run(ID, "tweaker", function()
            H.state().failures[RECORD] = { rename = true }
            return { success = true, new_version = "4.9.0" }
        end)
        assert.is_false(r.success)
        assert.is_true(r.applied)
        assert.equal("working", U.restart_status(ID).state)
        restarted()
        assert.is_false(U.restart_status(ID).ready)
        assert_no_restart()
    end)

    for _, failure in ipairs({ "open", "write", "close", "rename" }) do
        it("does not mutate before initial tracking " .. failure .. " succeeds", function()
            local path = failure == "rename" and RECORD or STAGES
            local W = begin({ failures = { [path] = { [failure] = true } } })
            local called = false
            local r = W.run(ID, "cache", function() called = true; return { success = true } end)
            assert.truthy(r.error)
            assert.is_false(called)
            assert.falsy(H.vfs_exists(RECORD))
            for _, stage in ipairs(H.stage_paths(STAGES)) do assert.falsy(H.vfs_exists(stage)) end
            assert.falsy(H.vfs_exists(LOCK))
        end)
    end

    it("does not mutate when exclusive restart-state allocation fails", function()
        local W = begin({ failures = { [STAGES] = { mktemp = true } } })
        local called = false
        local response = W.run(ID, "cache", function() called = true; return { success = true } end)
        assert.truthy(response.error)
        assert.is_false(called)
        assert.same({}, H.stage_paths(STAGES))
        assert_no_restart()
    end)

    it("keeps old fixed temporary names untouched and accepts legacy evidence without a queue field", function()
        local W, U = begin()
        local foreign = RECORD .. ".tmp-write"
        H.vfs_write(foreign, "another invocation's bytes")
        assert.is_true(W.run(ID, "tweaker", function() return { success = true, new_version = "4.9.0" } end).success)
        assert.equal("another invocation's bytes", H.vfs_read(foreign))
        local record = H.json.parse(H.vfs_read(RECORD))
        record.restart_queued = nil
        H.vfs_write(RECORD, H.json.stringify(record))
        restarted()
        assert.is_true(U.restart_status(ID).ready)
    end)

    for _, target in ipairs({ "tweaker", "theme", "cache" }) do
        it("excludes a competing " .. target .. " mutation even when the lock owner has no restart ID", function()
            local W = begin()
            local mutations, competing = 0, nil
            local first = W.run(nil, "tweaker", function()
                assert.truthy(H.vfs_exists(LOCK))
                local job = coroutine.create(function()
                    competing = W.run(ID, target, function() mutations = mutations + 1; return { success = true } end)
                end)
                local resumed, err = coroutine.resume(job)
                assert.is_true(resumed, err)
                assert.equal("dead", coroutine.status(job))
                mutations = mutations + 1
                return { success = true }
            end)
            assert.is_true(first.success)
            assert.truthy(competing.error)
            assert.is_false(competing.applied)
            assert.equal(1, mutations)
            assert.falsy(H.vfs_exists(RECORD), "legacy callers must not manufacture tracked evidence")
            assert.falsy(H.vfs_exists(LOCK))
        end)
    end

    it("locks before the initial evidence read so two absent-record checks cannot both mutate", function()
        local W = begin()
        local open = io.open
        local intercepted, competing, mutations = false, nil, 0
        io.open = function(path, mode)
            local fd, err, errno = open(path, mode)
            if path == RECORD and mode == "rb" and not intercepted then
                intercepted = true
                local job = coroutine.create(function()
                    competing = W.run(string.rep("b", 32), "theme", function()
                        mutations = mutations + 1
                        return { success = true, new_version = "3.0.0-r2" }
                    end)
                end)
                local resumed, resume_err = coroutine.resume(job)
                assert.is_true(resumed, resume_err)
            end
            return fd, err, errno
        end
        local first = W.run(ID, "cache", function() mutations = mutations + 1; return { success = true } end)
        assert.is_true(first.success)
        assert.is_true(intercepted)
        assert.truthy(competing.error)
        assert.equal(1, mutations)
        assert.equal(ID, H.json.parse(H.vfs_read(RECORD)).id)
    end)

    it("never steals an existing lock, including after evidence expires or the web process changes", function()
        local W, U = begin()
        H.vfs_mkdir(LOCK)
        H.vfs_write(LOCK .. "/owner", "retained for administrator inspection")
        H.vfs_write(RECORD, H.json.stringify({ id = ID, target = "cache", state = "working",
            started = os.time() - 1000, previous_instance = "100:1000" }))
        local called = false
        local response = W.run(ID, "cache", function() called = true; return { success = true } end)
        assert.truthy(response.error)
        assert.is_false(called)
        restarted()
        assert.truthy(U.restart_status(ID).error)
        assert.truthy(W.run("", "cache", function() called = true end).error)
        assert.is_false(called)
        assert.equal("retained for administrator inspection", H.vfs_read(LOCK .. "/owner"))
        assert.truthy(H.vfs_exists(LOCK))
        assert_no_restart()
    end)

    it("returns applied/unknown on lock release failure without replaying the completed operation", function()
        local W, U = begin({ failures = { [LOCK] = { rmdir = true } } })
        local mutations = 0
        local response = W.run(ID, "tweaker", function()
            mutations = mutations + 1
            return { success = true, new_version = "4.9.0", files_copied = 2 }
        end)
        assert.is_false(response.success)
        assert.is_true(response.applied)
        assert.is_true(response.unknown)
        assert.equal(ID, response.restart_id)
        assert.equal(2, response.files_copied)
        assert.truthy(response.details)
        assert.truthy(H.vfs_exists(LOCK))
        local writes = #H.stage_paths(STAGES)
        assert.is_false(U.restart_status(ID).ready)
        restarted()
        assert.is_true(U.restart_status(ID).ready, "read-only verification still requires the checked result, new instance and exact version")
        assert.truthy(W.run(string.rep("b", 32), "cache", function() mutations = mutations + 1 end).error)
        assert.equal(1, mutations)
        assert.equal(writes, #H.stage_paths(STAGES), "status/rejected competing requests must not publish evidence")
        assert.truthy(H.vfs_exists(LOCK))
    end)

    it("retains unknown evidence without asserting application after a mutation exception", function()
        local W, U = begin()
        local stage
        local response = W.run(ID, "cache", function()
            stage = assert(require("podkop-tweaker.services").stage_file("/owned-candidate", "unpublished bytes", { mode = "600" }))
            H.vfs_write("/partial", "applied bytes")
            error("interrupted after publication")
        end)
        assert.is_false(response.success)
        assert.is_false(response.applied)
        assert.is_true(response.unknown)
        assert.matches("interrupted after publication", response.details, 1, true)
        assert.is_string(stage)
        assert.falsy(H.vfs_exists(stage), "the exception must reach with_lock's owned-stage cleanup")
        assert.falsy(H.vfs_exists(LOCK))
        assert.equal("working", U.restart_status(ID).state)
        restarted()
        assert.is_false(U.restart_status(ID).ready)
        local replayed = false
        assert.truthy(W.run(string.rep("b", 32), "cache", function() replayed = true end).error)
        assert.is_false(replayed)
        assert.equal("applied bytes", H.vfs_read("/partial"))
        assert_no_restart()
    end)

    for _, applied in ipairs({ false, true }) do
        it("preserves a failed callback's diagnostics/metadata after release failure; applied=" .. tostring(applied), function()
            local W, U = begin({ failures = { [LOCK] = { rmdir = true } } })
            local details = string.rep("original diagnostic\n", 500) .. "primary-output-end"
            local warnings = { "retained backup", "manual recovery required" }
            local response = W.run(ID, "tweaker", function()
                if applied then H.vfs_write("/applied", "confirmed publication") end
                return { success = false, applied = applied, error = "Primary application failure", details = details,
                    phase = "copy", partial = applied, files_copied = applied and 1 or 0, new_version = "4.9.1",
                    resume_available = true, staging_retained = true, warnings = warnings, lock_error = "inner resource error" }
            end)
            assert.is_false(response.success)
            assert.equal(applied, response.applied)
            assert.is_true(response.unknown)
            assert.equal("Primary application failure", response.error)
            assert.equal(details, response.details:sub(1, #details))
            assert.matches("cannot release owned lock", response.details, 1, true)
            assert.equal("inner resource error", response.lock_error)
            assert.matches("web%-update", response.web_lock_error)
            assert.equal("copy", response.phase)
            assert.equal(applied, response.partial)
            assert.equal(applied and 1 or 0, response.files_copied)
            assert.equal("4.9.1", response.new_version)
            assert.is_true(response.resume_available)
            assert.is_true(response.staging_retained)
            assert.same(warnings, response.warnings)
            assert.equal(ID, response.restart_id)
            assert.equal("failed", U.restart_status(ID).state)
            assert.falsy(U.restart_status(ID).ready)
            assert.truthy(H.vfs_exists(LOCK))
            assert_no_restart()
        end)

        it("does not manufacture application evidence when writing a failed callback result also fails; applied=" .. tostring(applied), function()
            local W, U = begin()
            local response = W.run(ID, "theme", function()
                H.state().failures[RECORD] = { rename = true }
                return { success = false, applied = applied, error = "Primary package failure", details = "full native output",
                    phase = "translation", partial = applied, resume_available = true, package = "locale" }
            end)
            assert.is_false(response.success)
            assert.equal(applied, response.applied)
            assert.is_true(response.unknown)
            assert.equal("Primary package failure", response.error)
            assert.matches("full native output\nCannot record operation result", response.details, 1, true)
            assert.matches("Injected rename failure", response.details, 1, true)
            assert.equal("translation", response.phase)
            assert.equal(applied, response.partial)
            assert.is_true(response.resume_available)
            assert.equal("locale", response.package)
            assert.equal(ID, response.restart_id)
            assert.equal("working", U.restart_status(ID).state)
            assert_no_restart()
        end)
    end

    it("treats a release failure before the mutation callback as unknown, not applied", function()
        local W = begin({ failures = { [STAGES] = { mktemp = true }, [LOCK] = { rmdir = true } } })
        local invoked = false
        local response = W.run(ID, "cache", function() invoked = true; return { success = true } end)
        assert.is_false(invoked)
        assert.is_false(response.success)
        assert.is_false(response.applied)
        assert.is_true(response.unknown)
        assert.equal("Cannot create restart state", response.error)
        assert.matches("Cannot allocate an owned temporary file", response.details, 1, true)
        assert.matches("cannot release owned lock", response.details, 1, true)
        assert.truthy(H.vfs_exists(LOCK))
        assert_no_restart()
    end)

    for _, extra in ipairs({ { partial = true }, { error = "Finishing failed" }, { unknown = true } }) do
        it("does not queue a contradictory success result with " .. next(extra), function()
            local W, U = begin()
            extra.success = true
            local response = W.run(ID, "cache", function() return extra end)
            assert.is_false(response.success)
            restarted()
            assert.is_false(U.restart_status(ID).ready)
            assert_no_restart()
        end)
    end

    for _, launched in ipairs({ false, true }) do
        it("does not confirm unrecorded restart scheduling after launcher " .. (launched and "success" or "failure"), function()
            local W, U = begin({ execute = { { match = "uhttpd restart", out = function()
                H.state().failures[RECORD] = { rename = true }
                return launched and 0 or 256
            end } } })
            local response = W.run(ID, "tweaker", function() return { success = true, new_version = "4.9.0" } end)
            assert.is_false(response.success)
            assert.is_true(response.applied)
            assert.equal(ID, response.restart_id)
            restarted()
            assert.is_false(U.restart_status(ID).ready)
            assert.is_false(H.json.parse(H.vfs_read(RECORD)).restart_queued)
        end)
    end
end)
