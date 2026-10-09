package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path
local H = require("pt_harness")
local ID = string.rep("a", 32)
local RECORD = "/tmp/pt-web-restart.json"
local function stat(start)
    return "100 (uhttpd) S " .. string.rep("0 ", 18) .. start .. "\n"
end
local function begin(opts)
    opts = opts or {}
    opts.sys = opts.sys or { { match = "pidof uhttpd", out = "101 100\n" } }
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
            local path = failure == "rename" and RECORD or RECORD .. ".tmp-write"
            local W = begin({ failures = { [path] = { [failure] = true } } })
            local called = false
            local r = W.run(ID, "cache", function() called = true; return { success = true } end)
            assert.truthy(r.error)
            assert.is_false(called)
            assert.falsy(H.vfs_exists(RECORD))
        end)
    end
end)
