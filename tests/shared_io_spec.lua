-- Owned publication / interprocess-lock contracts. Every IO/process is virtual;
-- these fixtures do not establish native mktemp, POSIX locks or router readiness.
package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path
local H = require("pt_harness")

after_each(function() H.finish() end)

local function begin(opts)
    opts = opts or {}
    opts.strict = true
    H.begin(opts)
    return require("podkop-tweaker.services")
end

local function mktemp_command(template)
    -- Independent literal contract: do not use the production allocator here.
    local word = "'" .. template:gsub("'", "'\\''") .. "'"
    return "umask 077; mktemp " .. word .. " 2>&1; printf '\\nPT_MKTEMP_EXIT:%s\\n' \"$?\""
end

local function allocate(template)
    local pipe = assert(io.popen(mktemp_command(template), "r"))
    local output = pipe:read("*a")
    assert.is_true(pipe:close())
    return output
end

local function events(operation, path)
    local found = {}
    for _, event in ipairs(H.state().io_log) do
        if event.operation == operation and (not path or event.path == path) then found[#found + 1] = event end
    end
    return found
end

describe("native-boundary harness model", function()
    it("reserves exclusive private mktemp paths before broad network callbacks", function()
        local network_calls = 0
        begin({ popen = function() network_calls = network_calls + 1; return "" end })
        local template = "/config.tmp-import.XXXXXX"
        H.vfs_write("/config.tmp-import.000001", "foreign file")
        H.vfs_mkdir("/config.tmp-import.000002")
        assert.equal("/config.tmp-import.000003\n\nPT_MKTEMP_EXIT:0\n", allocate(template))
        assert.equal("", H.vfs_read("/config.tmp-import.000003"))
        assert.equal("600", H.vfs_mode("/config.tmp-import.000003"))
        assert.equal(0, network_calls)
        assert.equal("foreign file", H.vfs_read("/config.tmp-import.000001"))
        assert.truthy(H.state().dirs["/config.tmp-import.000002"])
        assert.is_nil(H.vfs_read(template))
        assert.is_nil(H.vfs_read("/config.tmp-import"))
        assert.is_true(os.remove("/config.tmp-import.000003"))
        assert.equal("/config.tmp-import.000004\n\nPT_MKTEMP_EXIT:0\n", allocate(template))
        assert.same({ "/config.tmp-import.000003", "/config.tmp-import.000004" }, H.stage_paths("/config.tmp-import.*"))
        assert.equal("/config.tmp-import.000004", H.last_stage("/config.tmp-import.*"))
        assert.equal(mktemp_command(template), H.allocations()[1].command)
        assert.equal("/config.tmp-import.000003", events("mktemp")[1].path)
    end)

    it("keeps literal spaces and apostrophes in the actual allocated pathname", function()
        begin()
        local template = "/tmp/router's config.tmp.XXXXXX"
        local output = allocate(template)
        local path = assert(output:match("^(.-)\n\nPT_MKTEMP_EXIT:0\n$"))
        assert.equal("/tmp/router's config.tmp.000001", path)
        assert.equal(path, H.last_stage())
        assert.truthy(H.vfs_exists(path))
    end)

    it("does not auto-accept a different mktemp command as the owned allocation primitive", function()
        begin()
        for _, command in ipairs({ "mktemp '/config.tmp.XXXXXX'",
            "umask 077; mktemp /config.tmp.XXXXXX 2>&1; printf '\\nPT_MKTEMP_EXIT:%s\\n' \"$?\"" }) do
            local pipe = assert(io.popen(command, "r"))
            assert.matches("PT_EXIT:125\n$", pipe:read("*a"))
            assert.is_true(pipe:close())
        end
        assert.same({}, H.allocations())
        assert.equal(2, #H.state().unexpected)
        local ok, err = pcall(H.finish)
        assert.is_false(ok)
        assert.matches("Unexpected harness calls", err)
    end)

    for _, rule in ipairs({ "/config.tmp-write.XXXXXX", "/config.tmp-write.*", "/config.tmp-write.000001" }) do
        local pattern = rule
        it("can explicitly fail allocation by " .. pattern, function()
            begin({ failures = { [pattern] = { mktemp = true } }, popen = function() return "" end })
            assert.matches("PT_MKTEMP_EXIT:1\n$", allocate("/config.tmp-write.XXXXXX"))
            assert.same({}, H.allocations())
            assert.same({}, H.state().vfs)
            assert.is_false(events("mktemp")[1].success)
        end)
    end

    it("uses exact then longest literal-prefix failure rules without stage aliases", function()
        begin({ failures = {
            ["/tmp/*"] = { open = true },
            ["/tmp/config[1].tmp.*"] = { close = true },
            ["/tmp/config[1].tmp.000001"] = { read = true }
        } })
        local exact = "/tmp/config[1].tmp.000001"
        local prefix = "/tmp/config[1].tmp.000002"
        H.vfs_write(exact, "first")
        H.vfs_write(prefix, "second")
        local fd = assert(io.open(exact, "rb"))
        assert.is_nil(fd:read(1))
        assert.is_true(fd:close())
        fd = assert(io.open(prefix, "rb"))
        assert.equal("second", fd:read(20))
        assert.is_nil(fd:close())
        assert.is_nil(io.open("/tmp/config1.tmp.000002", "rb"))
        -- Module loading may probe LuaRocks manifests through the same overlay.
        -- Retain those actual paths in io_log; inspect this fixture's domain.
        local opened = {}
        for _, event in ipairs(events("open")) do
            if event.path:sub(1, #"/tmp/config") == "/tmp/config" then opened[#opened + 1] = event.path end
        end
        assert.same({ exact, prefix, "/tmp/config1.tmp.000002" }, opened)
    end)

    for _, path in ipairs({ "/var/lock/podkop-tweaker-podkop.lock", "/var/lock/podkop-fragment.lock" }) do
        local lock = path
        it("models atomic mkdir/rmdir despite broad success observers for " .. lock, function()
            local S = begin({ popen = function() return "" end, execute = { { match = function() return true end, out = 0 } },
                sys = { { match = function() return true end, out = "\nPT_EXIT:0\n" } } })
            local LIB = require("podkop-tweaker.lib")
            local mkdir = "mkdir '" .. lock .. "' 2>/dev/null"
            local rmdir = "rmdir '" .. lock .. "' 2>/dev/null"
            assert.is_true(LIB.exit_ok(os.execute(mkdir)))
            assert.is_false(LIB.exit_ok(os.execute(mkdir)))
            local sys = require("luci.sys")
            assert.matches("PT_EXIT:1\n$", sys.exec(S.checked_command(mkdir)))
            local pipe = assert(io.popen(S.checked_command(mkdir), "r"))
            assert.matches("PT_EXIT:1\n$", pipe:read("*a"))
            assert.is_true(pipe:close())
            H.vfs_write(lock .. "/owner", "another process")
            assert.is_false(LIB.exit_ok(os.execute(rmdir)))
            assert.truthy(H.state().dirs[lock])
            assert.is_true(os.remove(lock .. "/owner"))
            assert.matches("PT_EXIT:0\n$", sys.exec(S.checked_command(rmdir)))
            assert.falsy(H.state().dirs[lock])
            assert.is_false(LIB.exit_ok(os.execute(rmdir)))
        end)
    end

    it("honors explicit lock failure flags without consuming another resource", function()
        begin({ failures = { ["/var/lock/podkop-tweaker-subscriptions.lock"] = { mkdir = true } } })
        local lock = "/var/lock/podkop-tweaker-subscriptions.lock"
        assert.not_equal(0, os.execute("mkdir '" .. lock .. "' 2>/dev/null"))
        assert.falsy(H.vfs_exists(lock))
        H.state().failures[lock] = { rmdir = true }
        assert.equal(0, os.execute("mkdir '" .. lock .. "' 2>/dev/null"))
        assert.not_equal(0, os.execute("rmdir '" .. lock .. "' 2>/dev/null"))
        assert.truthy(H.state().dirs[lock])
    end)

    it("returns native numeric-read EOF nil for both files and pipes", function()
        begin({ popen = { { match = "fixture-reader", out = "abc" } } })
        H.vfs_write("/file", "abc")
        for _, fd in ipairs({ assert(io.open("/file", "rb")), assert(io.popen("fixture-reader", "r")) }) do
            assert.equal("", fd:read(0))
            assert.equal("ab", fd:read(2))
            assert.equal("c", fd:read(2))
            local bytes, err = fd:read(2)
            assert.is_nil(bytes)
            assert.is_nil(err)
            assert.is_nil(fd:read(0))
            assert.equal("", fd:read("*a"))
            assert.is_true(fd:close())
        end
    end)

    it("reports unexpected critical commands at teardown even after a caught error", function()
        local original_open = io.open
        local S = begin()
        local sys = require("luci.sys")
        pcall(function()
            assert.matches("PT_EXIT:125\n$", sys.exec(S.checked_command("fixture-write")))
            assert.equal(125, os.execute("flock /var/lock/fixture.lock true"))
            local pipe = assert(io.popen(S.checked_command("fixture-write"), "r"))
            assert.matches("PT_EXIT:125\n$", pipe:read("*a"))
            assert.is_true(pipe:close())
            error("caught by a transport adapter")
        end)
        assert.equal(3, #H.state().unexpected)
        local ok, err = pcall(H.finish)
        assert.is_false(ok)
        assert.matches("Unexpected harness calls", err)
        assert.equal(original_open, io.open, "teardown must restore globals before it fails")
        assert.is_nil(H.state())
    end)

    it("does not stringify a nil HTTP write in strict mode", function()
        begin()
        assert.is_false(pcall(H.http().write, nil))
        assert.equal("", H.body())
        local ok, err = pcall(H.finish)
        assert.is_false(ok)
        assert.matches("http.write: nil body", err, 1, true)
    end)

    it("models unambiguous UCI mutation failures without directory-aware cursors", function()
        begin({ uci = { argon = { H.sec("global", "global", { mode = "dark" }) } },
            uci_failures = { argon = { commit = true } } })
        local UCI = require("luci.model.uci")
        local uci = UCI.cursor("/ignored-confdir", "/ignored-savedir")
        assert.equal("dark", uci:get("argon", "global", "mode"))
        assert.is_false(uci:set("argon", "missing", "font_size", "20"))
        assert.is_nil(uci:get("argon", "missing"))
        assert.is_false(uci:delete("argon", "missing"))
        assert.is_false(uci:commit("argon"))
        H.state().uci_failures.argon = { set = true }
        assert.is_false(uci:set("argon", "global", "mode", "light"))
        assert.equal("dark", uci:get("argon", "global", "mode"))
        H.state().uci_failures.argon = {}
        assert.is_true(uci:delete("argon", "global"))
        assert.is_nil(uci:get("argon", "global"))
        assert.is_false(uci:foreach("missing", nil, function() error("must not be called") end))
    end)

    it("keeps legacy read-only fixtures and their explicit checked-command defaults", function()
        H.begin()
        assert.equal("", require("luci.sys").exec("uname -r"))
        assert.equal("\nPT_EXIT:0\n", require("luci.sys").exec("fixture; printf '\\nPT_EXIT:%s\\n' \"$?\""))
        assert.same({}, H.state().unexpected)
    end)
end)

describe("owned adjacent stages", function()
    it("allocates different private files for the same suffix and publishes exact staged bytes", function()
        local S = begin()
        H.vfs_write("/config", "old")
        H.vfs_write("/config.tmp-import", "foreign predictable name")
        local first = assert(S.stage_file("/config", "first checked bytes", { suffix = ".tmp-import" }))
        local second = assert(S.stage_file("/config", "second checked bytes", { suffix = ".tmp-import" }))
        assert.not_equal(first, second)
        assert.matches("^/config%.tmp%-import%.[%w]+$", first)
        assert.matches("^/config%.tmp%-import%.[%w]+$", second)
        assert.same({ first, second }, H.stage_paths("/config.tmp-import.*"))
        assert.equal(mktemp_command("/config.tmp-import.XXXXXX"), H.allocations()[1].command)
        for _, path in ipairs({ first, second }) do
            local writes = events("write", path)
            assert.is_true(#writes > 0)
            for _, write in ipairs(writes) do assert.equal("600", write.mode, "private before any bytes") end
        end
        assert.is_true(S.publish_file(first, "/config"))
        assert.equal("first checked bytes", H.vfs_read("/config"))
        assert.equal("second checked bytes", H.vfs_read(second))
        assert.is_false(S.publish_file(first, "/config"), "a consumed stage cannot be published twice")
        S.discard_stage(second)
        assert.falsy(H.vfs_exists(first))
        assert.falsy(H.vfs_exists(second))
        assert.equal("foreign predictable name", H.vfs_read("/config.tmp-import"))
        assert.equal(first, events("rename")[1].path)
        assert.equal("first checked bytes", events("rename")[1].content)
    end)

    it("does not publish or discard a plausible but unregistered foreign stage", function()
        local S = begin()
        local foreign = "/config.tmp-write.foreign"
        H.vfs_write("/config", "old")
        H.vfs_write(foreign, "another actor's bytes")
        assert.is_false(S.publish_file(foreign, "/config"))
        S.discard_stage(foreign)
        assert.equal("old", H.vfs_read("/config"))
        assert.equal("another actor's bytes", H.vfs_read(foreign))
        assert.same({}, events("rename"))
        assert.same({}, events("remove", foreign))
    end)

    it("binds a registered stage to its exact target rather than an adjacent pathname", function()
        local S = begin()
        H.vfs_write("/config", "old config")
        H.vfs_write("/config-other", "other config")
        local stage = assert(S.stage_file("/config", "new config"))
        assert.is_false(S.publish_file(stage, "/config-other"))
        assert.equal("old config", H.vfs_read("/config"))
        assert.equal("other config", H.vfs_read("/config-other"))
        S.discard_stage(stage)
    end)

    for _, bytes in ipairs({ "", "bad config" }) do
        local replacement = bytes
        it("rejects stage bytes replaced with " .. (replacement == "" and "an empty file" or "same-size invalid content"), function()
            local S = begin()
            H.vfs_write("/config", "old config")
            local stage = assert(S.stage_file("/config", "new config"))
            H.vfs_write(stage, replacement)
            assert.is_false(S.publish_file(stage, "/config"))
            assert.equal("old config", H.vfs_read("/config"))
            assert.same({}, events("rename"))
            S.discard_stage(stage)
        end)
    end

    for _, operation in ipairs({ "read", "close" }) do
        local failure = operation
        it("rejects publication when the owned stage cannot complete its " .. failure, function()
            local S = begin()
            H.vfs_write("/config", "old config")
            local stage = assert(S.stage_file("/config", "new config"))
            H.state().failures[stage] = { [failure] = true }
            assert.is_false(S.publish_file(stage, "/config"))
            assert.equal("old config", H.vfs_read("/config"))
            assert.same({}, events("rename"))
            S.discard_stage(stage)
        end)
    end

    it("cannot regain ownership by recreating a successfully consumed physical pathname", function()
        local S = begin()
        local stage = assert(S.stage_file("/config", "first"))
        assert.is_true(S.publish_file(stage, "/config"))
        H.vfs_write(stage, "foreign recreation")
        assert.is_false(S.publish_file(stage, "/config"))
        S.discard_stage(stage)
        assert.equal("first", H.vfs_read("/config"))
        assert.equal("foreign recreation", H.vfs_read(stage))
    end)
end)

describe("resource lock ownership", function()
    local keys = { podkop = "/var/lock/podkop-tweaker-podkop.lock", stubby = "/var/lock/podkop-tweaker-stubby.lock",
        singbox = "/var/lock/podkop-fragment.lock", subscriptions = "/var/lock/podkop-tweaker-subscriptions.lock",
        ["argon-css"] = "/var/lock/podkop-tweaker-argon-css.lock", ["web-update"] = "/var/lock/podkop-tweaker-web-update.lock" }

    for key, path in pairs(keys) do
        local resource, lock = key, path
        it("uses the fixed mkdir resource for " .. resource .. " and preserves callback return values", function()
            local S = begin()
            local first, middle, last = S.with_lock(resource, function()
                assert.truthy(H.state().dirs[lock])
                return "applied", nil, "metadata"
            end)
            assert.equal("applied", first)
            assert.is_nil(middle)
            assert.equal("metadata", last)
            assert.falsy(H.vfs_exists(lock))
            assert.equal(1, #events("mkdir", lock))
            assert.equal(1, #events("rmdir", lock))
        end)
    end

    it("is reentrant only for the same coroutine, not another logical request", function()
        local S = begin({ execute = { { match = function() return true end, out = 0 } } })
        local lock = keys.singbox
        assert.equal("outer", S.with_lock("singbox", function()
            assert.equal("inner", S.with_lock("singbox", function() return "inner" end))
            assert.equal(1, #events("mkdir", lock), "same owner must not attempt a second native mkdir")
            local entered = false
            local contender = coroutine.create(function()
                return S.with_lock("singbox", function() entered = true; return "wrong actor" end)
            end)
            local resumed, value, err = coroutine.resume(contender)
            assert.is_true(resumed)
            assert.is_nil(value)
            assert.equal("string", type(err))
            assert.is_false(entered)
            assert.truthy(H.state().dirs[lock])
            return "outer"
        end))
        assert.falsy(H.vfs_exists(lock))
        assert.equal(1, #events("rmdir", lock))
    end)

    it("does not steal or release a foreign shell-patcher lock", function()
        local S = begin({ execute = { { match = function() return true end, out = 0 } } })
        local lock, entered = keys.singbox, false
        H.vfs_mkdir(lock)
        local value, err = S.with_lock("singbox", function() entered = true end)
        assert.is_nil(value)
        assert.equal("string", type(err))
        assert.is_false(entered)
        assert.truthy(H.state().dirs[lock])
        assert.same({}, events("rmdir", lock))
    end)

    it("cleans only this owner's stages and lock when the callback raises", function()
        local S = begin()
        local foreign = "/config.tmp-write.foreign"
        H.vfs_write(foreign, "unregistered bytes")
        H.vfs_mkdir(keys.stubby)
        local other_actor = coroutine.create(function() return S.stage_file("/other", "other actor's stage") end)
        local resumed, other_stage = coroutine.resume(other_actor)
        assert.is_true(resumed)
        assert.equal("string", type(other_stage))
        local owned_stage
        local ok, err = pcall(function()
            S.with_lock("podkop", function()
                owned_stage = assert(S.stage_file("/config", "owned stage"))
                error("fixture callback exception")
            end)
        end)
        assert.is_false(ok)
        assert.matches("fixture callback exception", err, 1, true)
        assert.falsy(H.vfs_exists(owned_stage))
        assert.falsy(H.vfs_exists(keys.podkop))
        assert.equal("unregistered bytes", H.vfs_read(foreign))
        assert.equal("other actor's stage", H.vfs_read(other_stage))
        assert.truthy(H.state().dirs[keys.stubby])
        assert.same({}, events("remove", other_stage))
        assert.same({}, events("remove", foreign))
        assert.equal("recovered", S.with_lock("podkop", function() return "recovered" end))
    end)

    it("reports acquisition failure without invoking the callback", function()
        local S = begin({ failures = { [keys.subscriptions] = { mkdir = true } } })
        local value, err = S.with_lock("subscriptions", function() error("must not run") end)
        assert.is_nil(value)
        assert.equal("string", type(err))
        assert.falsy(H.vfs_exists(keys.subscriptions))
        assert.same({}, events("rmdir", keys.subscriptions))
    end)

    it("reports a failed release with applied uncertainty and retains the lock for inspection", function()
        local S = begin({ failures = { [keys.subscriptions] = { rmdir = true } } })
        local value, err, applied = S.with_lock("subscriptions", function()
            H.vfs_write("/state", "applied")
            return { success = true }
        end)
        assert.is_nil(value)
        assert.equal("string", type(err))
        assert.is_true(applied)
        assert.equal("applied", H.vfs_read("/state"))
        assert.truthy(H.state().dirs[keys.subscriptions])
        local contender = coroutine.create(function() return S.with_lock("subscriptions", function() return "wrong" end) end)
        local resumed, result = coroutine.resume(contender)
        assert.is_true(resumed)
        assert.is_nil(result)
        assert.truthy(H.state().dirs[keys.subscriptions])
    end)

    it("rejects unsafe resource names before any command or callback", function()
        local S = begin()
        for _, key in ipairs({ "../podkop", "podkop;false", "podkop/other" }) do
            local value, err = S.with_lock(key, function() error("must not run") end)
            assert.is_nil(value)
            assert.equal("string", type(err))
        end
        assert.same({}, H.execute_cmds())
        assert.same({}, H.exec_cmds())
        assert.same({}, H.popen_cmds())
    end)
end)
