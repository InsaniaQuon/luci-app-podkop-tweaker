-- IO1/IO2 contracts: actual allocated stage identities, checked exits, usable
-- backups and source/actor guards. IO, sing-box and service commands are fakes.
package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path
local H = require("pt_harness")

local PODKOP_OLD = "config podkop 'main'\n\toption enabled '0'\n"
local PODKOP_NEW = "config podkop 'main'\n\toption enabled '1'\n"
local STUBBY_OLD = "config stubby 'global'\n\toption log_level '3'\n"
local STUBBY_NEW = "config stubby 'global'\n\toption log_level '4'\n"
local SB_OLD = '{"outbounds":[{"type":"direct","tag":"old"}]}'
local SB_NEW = '{"outbounds":[{"type":"direct","tag":"new"}]}'
local SB_FOREIGN = '{"outbounds":[{"type":"direct","tag":"other"}]}'
local CFG, BAK = "/etc/sing-box/config.json", "/etc/sing-box/config.json.auto-backup"
local active_fixture

local function checked_output(text, code)
    return (text or "") .. "\nPT_EXIT:" .. tostring(code or 0) .. "\n"
end

local function begin(opts)
    opts = opts or {}
    local fixture = { checks = {}, restarts = {} }
    local scripts = {
        { match = "sing-box check -c ", out = function(command)
            -- Only a real allocation named in the command can be validated.
            -- Never alias an old fixed suffix to whichever stage happens to exist.
            local path
            for _, allocation in ipairs(H.allocations()) do
                if command:find("'" .. allocation.path .. "'", 1, true) then path = allocation.path; break end
            end
            local bytes = path and H.vfs_read(path)
            fixture.checks[#fixture.checks + 1] = { path = path, bytes = bytes, command = command }
            local output
            if opts.check_output ~= nil then
                output = type(opts.check_output) == "function" and opts.check_output(bytes, path, command) or opts.check_output
            else
                -- The external checker is controlled, not a sing-box implementation.
                local parsed = bytes and H.json.parse(bytes)
                output = parsed and bytes:match("^%s*{") and checked_output("", 0) or checked_output("invalid fixture JSON", 1)
            end
            if opts.on_check then opts.on_check(path, bytes, command) end
            return output
        end },
        { match = function(command)
            return command:find("/etc/init.d/podkop restart", 1, true) or
                command:find("/etc/init.d/stubby restart", 1, true) or command:find("/etc/init.d/sing-box restart", 1, true)
        end, out = function(command)
            fixture.restarts[#fixture.restarts + 1] = command
            return opts.restart_output or checked_output("", 0)
        end },
        { match = "pidof ", out = function(command)
            return opts.pid_output or (command:find("PT_EXIT:", 1, true) and checked_output("", 1) or "")
        end },
        { match = function(command)
            return command:find("'/etc/init.d/", 1, true) and
                (command:find("' start)", 1, true) or command:find("' stop)", 1, true))
        end, out = function()
            return opts.toggle_output or checked_output("", 0)
        end }
    }
    H.begin({ strict = true, failures = opts.failures, execute = opts.execute, sys = scripts, popen = scripts })
    active_fixture = fixture
    return require("podkop-tweaker.services"), fixture
end

after_each(function()
    local fixture = active_fixture
    active_fixture = nil
    -- Always restore the harness before asserting command facts outside any
    -- production pcall. A fake cannot turn a swallowed assertion into evidence.
    H.finish()
    if not fixture then return end
    for _, check in ipairs(fixture.checks) do
        assert.equal("string", type(check.path), "native validation must use an actual owned stage")
        assert.equal("string", type(check.bytes))
        assert.not_equal(CFG, check.path)
        assert.not_equal(BAK, check.path)
        assert.truthy(check.command:find("</dev/null", 1, true), "checked foreground command occupies stdin")
        assert.truthy(check.command:find("PT_EXIT:", 1, true), "validator exit evidence is required")
    end
    for _, command in ipairs(fixture.restarts) do
        assert.truthy(command:find("</dev/null", 1, true))
        assert.truthy(command:find("PT_EXIT:", 1, true))
    end
end)

describe("observed service-toggle outcomes", function()
    for _, case in ipairs({ { action = "start", pid = checked_output("", 1), running = false },
        { action = "stop", pid = checked_output("55", 0), running = true } }) do
        it("does not confirm " .. case.action .. " when the checked command leaves the opposite observed state", function()
            local S = begin({ pid_output = case.pid })
            H.vfs_write("/proc/55/stat", "55 (sing-box) S " .. string.rep("0 ", 18) .. "400\n")
            local result = S.service_toggle("singbox", case.action)
            assert.is_false(result.success)
            assert.is_true(result.command_accepted)
            assert.is_true(result.unknown)
            assert.falsy(result.applied)
            assert.equal(case.running, result.running)
            assert.truthy(result.error)
        end)
    end
end)

local function assert_stages_cleaned(pattern)
    for _, path in ipairs(H.stage_paths(pattern)) do assert.falsy(H.vfs_exists(path), path .. " leaked") end
end

local function assert_no_publication(path)
    for _, event in ipairs(H.state().io_log) do
        assert.falsy(event.operation == "rename" and event.target == path and event.success,
            "failed prepublication work must not rename over " .. path)
        assert.falsy(event.operation == "write" and event.path == path, "live bytes must not be written in place")
    end
end

local function assert_error(response)
    assert.is_table(response)
    assert.is_false(response.success)
    assert.equal("string", type(response.error))
    assert.not_equal("", response.error)
end

local function assert_warning(response)
    local warning = response.warning or response.warnings
    assert.truthy(warning, "a skipped invalid-source backup needs an explicit warning")
    if type(warning) == "table" then assert.is_not_nil(next(warning))
    else assert.equal("string", type(warning)); assert.not_equal("", warning) end
end

describe("service descriptor boundaries", function()
    it("rejects copied and arbitrary descriptors before validation, publication or service commands", function()
        local S, fixture = begin()
        local foreign_config, foreign_backup = "/etc/config/foreign", "/etc/config/foreign.auto-backup"
        H.vfs_write(S.podkop.config, PODKOP_OLD)
        H.vfs_write(S.podkop.backup, PODKOP_OLD)
        H.vfs_write(foreign_config, PODKOP_OLD)
        H.vfs_write(foreign_backup, PODKOP_OLD)
        for _, descriptor in ipairs({
            { config = S.podkop.config, backup = S.podkop.backup, restart_cmd = S.podkop.restart_cmd },
            { config = foreign_config, backup = foreign_backup, restart_cmd = S.podkop.restart_cmd }
        }) do
            local valid, validation_err = S.validate_service(descriptor, PODKOP_NEW)
            assert.is_false(valid)
            assert.equal("Unknown service", validation_err)
            assert_error(S.apply_service(descriptor, PODKOP_NEW))
            local backed, backup_err = S.backup_current(descriptor)
            assert.is_false(backed)
            assert.equal("Unknown service", backup_err)
            local restored, restore_err = S.restore_backup(descriptor)
            assert.is_false(restored)
            assert.equal("Unknown service", restore_err)
        end
        for _, path in ipairs({ S.podkop.config, S.podkop.backup, foreign_config, foreign_backup }) do
            assert.equal(PODKOP_OLD, H.vfs_read(path))
            assert_no_publication(path)
        end
        assert.same({}, H.allocations())
        assert.same({}, H.exec_cmds())
        assert.same({}, H.execute_cmds())
        assert.same({}, H.popen_cmds())
        assert.same({}, fixture.restarts)
    end)
end)

describe("checked bounded file IO", function()
    it("returns ENOENT only for a genuinely missing file", function()
        local S = begin()
        local bytes, err, errno = S.read_file("/missing", 20)
        assert.is_nil(bytes)
        assert.equal("string", type(err))
        assert.equal(2, errno)
        assert.same({}, H.allocations())
    end)

    for _, case in ipairs({
        { name = "open", failure = { open = true, errno = 13 } },
        { name = "read", failure = { read = true } },
        { name = "close", failure = { close = true } },
        { name = "size limit", limit = 2 }
    }) do
        local test = case
        it("reports IO errno 5 rather than ENOENT for " .. test.name .. " failure", function()
            local S = begin({ failures = { ["/config"] = test.failure } })
            H.vfs_write("/config", "old bytes")
            local bytes, err, errno = S.read_file("/config", test.limit or 20)
            assert.is_nil(bytes)
            assert.equal("string", type(err))
            assert.equal(5, errno)
            assert.equal("old bytes", H.vfs_read("/config"))
            assert_no_publication("/config")
        end)
    end

    it("reads exact bytes at the limit and distinguishes empty content from missing", function()
        local S = begin()
        H.vfs_write("/config", "a\0b\n")
        assert.equal("a\0b\n", S.read_file("/config", 4))
        H.vfs_write("/empty", "")
        local bytes, err, errno = S.read_file("/empty", 4)
        assert.equal("", bytes)
        assert.is_nil(err)
        assert.is_nil(errno)
    end)

    for _, operation in ipairs({ "open", "write", "close" }) do
        local fail = operation
        it("keeps the original on unique temporary " .. fail .. " failure", function()
            local S = begin({ failures = { ["/config.tmp-write.*"] = { [fail] = true, partial = 2 } } })
            H.vfs_write("/config", "old")
            H.vfs_write("/config.tmp-write.foreign", "another actor")
            assert.is_false(S.write_file_atomic("/config", "new config"))
            assert.equal("old", H.vfs_read("/config"))
            assert.equal("another actor", H.vfs_read("/config.tmp-write.foreign"))
            assert.equal(1, #H.allocations())
            assert_stages_cleaned()
            assert_no_publication("/config")
        end)
    end

    it("leaves live and foreign bytes intact when native allocation fails", function()
        local S = begin({ failures = { ["/config.tmp-write.*"] = { mktemp = true } } })
        H.vfs_write("/config", "old")
        H.vfs_write("/config.tmp-write", "foreign fixed temporary")
        assert.is_false(S.write_file_atomic("/config", "new"))
        assert.equal("old", H.vfs_read("/config"))
        assert.equal("foreign fixed temporary", H.vfs_read("/config.tmp-write"))
        assert.same({}, H.allocations())
        assert_no_publication("/config")
    end)

    it("cleans only its failed rename stage without truncating the target", function()
        local S = begin({ failures = { ["/config"] = { rename = true } } })
        H.vfs_write("/config", "old")
        H.vfs_write("/config.tmp-write.foreign", "foreign")
        assert.is_false(S.write_file_atomic("/config", "new"))
        assert.equal("old", H.vfs_read("/config"))
        assert.equal("foreign", H.vfs_read("/config.tmp-write.foreign"))
        assert_stages_cleaned()
    end)

    it("does not replace an executable when its stage chmod fails", function()
        local S = begin({ failures = { ["/script.tmp-write.*"] = { chmod = true } } })
        H.vfs_write("/script", "old script")
        assert.is_false(S.write_file_atomic("/script", "new script", { executable = true }))
        assert.equal("old script", H.vfs_read("/script"))
        assert_stages_cleaned()
        assert_no_publication("/script")
    end)

    for _, case in ipairs({
        { name = "ordinary", options = {}, mode = "644" },
        { name = "executable", options = { executable = true }, mode = "755" },
        { name = "private", options = { mode = "600" }, mode = "600" },
        { name = "explicit mode over executable default", options = { executable = true, mode = "640" }, mode = "640" }
    }) do
        local test = case
        it("publishes " .. test.name .. " files with the contracted final mode", function()
            local S = begin()
            assert.is_true(S.write_file_atomic("/target", "new bytes", test.options))
            assert.equal("new bytes", H.vfs_read("/target"))
            assert.equal(test.mode, H.vfs_mode("/target"))
            assert.equal(1, #H.allocations())
            assert.equal("600", H.allocations()[1].mode, "allocation starts private regardless of final mode")
            assert_stages_cleaned()
        end)
    end

    it("distinguishes a missing optional backup source from an unreadable source", function()
        local S = begin({ failures = { ["/private"] = { open = true } } })
        H.vfs_write("/private", "unreadable")
        H.vfs_write("/backup", "last good")
        assert.is_true(S.backup_to("/missing", "/backup"))
        assert.is_false(S.backup_to("/missing", "/backup", true))
        assert.is_false(S.backup_to("/private", "/backup"))
        assert.equal("last good", H.vfs_read("/backup"))
        assert_no_publication("/backup")
    end)

    it("preserves the previous backup after a unique backup stage flush failure", function()
        local S = begin({ failures = { ["/backup.tmp.*"] = { close = true } } })
        H.vfs_write("/config", "current")
        H.vfs_write("/backup", "last good")
        assert.is_false(S.backup_to("/config", "/backup"))
        assert.equal("last good", H.vfs_read("/backup"))
        assert.equal(1, #H.stage_paths("/backup.tmp.*"))
        assert_stages_cleaned()
    end)
end)

describe("checked native exit evidence", function()
    for _, case in ipairs({
        { name = "empty stdout with nonzero exit", output = checked_output("", 17), code = 17 },
        { name = "missing marker", output = "" },
        { name = "unterminated success marker", output = "\nPT_EXIT:0" },
        { name = "invalid marker", output = "\nPT_EXIT:not-a-code\n" },
        { name = "non-final success marker", output = "\nPT_EXIT:0\nmore output\n" },
        { name = "earlier success followed by failure", output = "early\nPT_EXIT:0\nlate\nPT_EXIT:9\n", code = 9 }
    }) do
        local test = case
        it("does not infer success from " .. test.name, function()
            local scripts = { { match = "fixture-check", out = test.output } }
            H.begin({ strict = true, sys = scripts, popen = scripts })
            local S = require("podkop-tweaker.services")
            local ok, details, code = S.exec_checked("fixture-check")
            assert.is_false(ok)
            assert.equal("string", type(details))
            assert.equal(test.code, code)
        end)
    end

    it("accepts exit zero with stdout and retains complete diagnostics", function()
        local details = string.rep("full diagnostic context\n", 1000) .. "last line"
        local scripts = { { match = "fixture-check", out = checked_output(details, 0) } }
        H.begin({ strict = true, sys = scripts, popen = scripts })
        local ok, output, code = require("podkop-tweaker.services").exec_checked("fixture-check")
        assert.is_true(ok)
        assert.equal(details, output)
        assert.equal(0, code)
    end)
end)

describe("service validation and owned sing-box publication", function()
    it("uses native exit failure even when sing-box emits no stdout", function()
        local S, fixture = begin({ check_output = checked_output("", 23) })
        H.vfs_write(CFG, SB_OLD)
        H.vfs_write(BAK, SB_OLD)
        local ok, err = S.singbox_apply_checked(SB_NEW, ".tmp-import")
        assert.is_false(ok)
        assert.equal("string", type(err))
        assert.equal(SB_OLD, H.vfs_read(CFG))
        assert.equal(SB_OLD, H.vfs_read(BAK))
        assert.is_true(#fixture.checks > 0)
        assert.same({}, fixture.restarts)
        assert_stages_cleaned()
        assert_no_publication(CFG)
        assert_no_publication(BAK)
    end)

    it("allows successful checker output and never restarts through the legacy bool helper", function()
        local S, fixture = begin({ check_output = checked_output("harmless checker notice", 0) })
        H.vfs_write(CFG, SB_OLD)
        assert.is_true(S.singbox_apply_checked(SB_NEW, ".tmp-import"))
        assert.equal(SB_NEW, H.vfs_read(CFG))
        assert.equal(SB_OLD, H.vfs_read(BAK))
        assert.same({}, fixture.restarts)
        assert.is_true(#H.stage_paths(CFG .. ".tmp-import.*") > 0)
        assert_stages_cleaned()
    end)

    for _, service in ipairs({ "podkop", "stubby", "singbox" }) do
        local name = service
        it("rejects empty, whitespace, oversized and syntactically invalid " .. name .. " candidates", function()
            local S, fixture = begin()
            local oversized = name == "singbox" and string.rep("x", 2097153) or string.rep("x", 1048577)
            local invalid = name == "singbox" and '{"outbounds":' or "config test 'main'\n\toption bad 'unclosed\n"
            for _, bytes in ipairs({ "", " \t\r\n", oversized, invalid }) do
                local ok, err = S.validate_service(name, bytes)
                assert.is_false(ok)
                assert.equal("string", type(err))
            end
            assert.is_nil(H.vfs_read(S[name].config))
            assert.is_nil(H.vfs_read(S[name].backup))
            assert.same({}, fixture.restarts)
            assert_stages_cleaned()
        end)
    end

    it("does not publish bytes changed after the native check observed the candidate", function()
        local S, fixture = begin({ on_check = function(path, bytes)
            if bytes == SB_NEW then H.vfs_write(path, SB_OLD) end
        end })
        H.vfs_write(CFG, SB_OLD)
        H.vfs_write(BAK, SB_OLD)
        assert_error(S.apply_service("singbox", SB_NEW))
        assert.equal(SB_OLD, H.vfs_read(CFG))
        assert.equal(SB_OLD, H.vfs_read(BAK))
        assert.same({}, fixture.restarts)
        assert_no_publication(CFG)
        assert_stages_cleaned()
    end)

    it("does not overwrite another writer's live change during candidate validation", function()
        local changed = false
        local S, fixture = begin({ on_check = function(_, bytes)
            if bytes == SB_NEW and not changed then changed = true; H.vfs_write(CFG, SB_FOREIGN) end
        end })
        H.vfs_write(CFG, SB_OLD)
        H.vfs_write(BAK, SB_OLD)
        assert_error(S.apply_service("singbox", SB_NEW))
        assert.is_true(changed)
        assert.equal(SB_FOREIGN, H.vfs_read(CFG))
        assert.equal(SB_OLD, H.vfs_read(BAK))
        assert.same({}, fixture.restarts)
        assert_no_publication(CFG)
        assert_stages_cleaned()
    end)
end)

describe("usable service backup and restore", function()
    local services = {
        { name = "podkop", old = PODKOP_OLD, new = PODKOP_NEW, invalid = "config podkop 'main'\n\toption broken 'quote\n" },
        { name = "stubby", old = STUBBY_OLD, new = STUBBY_NEW, invalid = "config stubby 'global'\n\toption broken 'quote\n" },
        { name = "singbox", old = SB_OLD, new = SB_NEW, invalid = '{"outbounds":' }
    }

    for _, service in ipairs(services) do
        local test = service
        for _, source in ipairs({ { name = "empty", bytes = "" }, { name = "whitespace", bytes = " \t\n" },
            { name = "invalid", bytes = test.invalid } }) do
            local snapshot = source
            it("preserves a good " .. test.name .. " rollback copy when the source is " .. snapshot.name, function()
                local S, fixture = begin()
                local svc = S[test.name]
                H.vfs_write(svc.config, snapshot.bytes)
                H.vfs_write(svc.backup, test.old)
                local backed, backup_err, metadata = S.backup_current(svc)
                assert.equal("boolean", type(backed))
                assert.truthy(backup_err or metadata, "skipping an unusable source needs an explicit outcome")
                assert.equal(test.old, H.vfs_read(svc.backup))
                local response = S.apply_service(test.name, test.new, { restart = false })
                assert.is_true(response.success)
                assert_warning(response)
                assert.equal(test.new, H.vfs_read(svc.config))
                assert.equal(test.old, H.vfs_read(svc.backup))
                assert.same({}, fixture.restarts)
                assert_no_publication(svc.backup)
                assert_stages_cleaned()
            end)
        end

        it("validates a usable " .. test.name .. " snapshot before replacing the previous backup", function()
            local S, fixture = begin()
            local svc = S[test.name]
            H.vfs_write(svc.config, test.new)
            H.vfs_write(svc.backup, test.old)
            assert.is_true(S.backup_current(svc))
            assert.equal(test.new, H.vfs_read(svc.config))
            assert.equal(test.new, H.vfs_read(svc.backup))
            assert.same({}, fixture.restarts)
            assert_no_publication(svc.config)
            assert_stages_cleaned()
        end)

        it("keeps " .. test.name .. " first-install absence distinct from an existing source IO error", function()
            local S, fixture = begin()
            local svc = S[test.name]
            assert.is_true(S.apply_service(svc, test.old, { restart = false }).success)
            assert.equal(test.old, H.vfs_read(svc.config))
            assert.is_nil(H.vfs_read(svc.backup))
            H.state().failures[svc.config] = { open = true, errno = 5 }
            local response = S.apply_service(svc, test.new, { restart = false })
            assert_error(response)
            assert.equal(test.old, H.vfs_read(svc.config))
            assert.is_nil(H.vfs_read(svc.backup))
            assert.same({}, fixture.restarts)
            assert_stages_cleaned()
        end)

        for _, backup in ipairs({ { name = "empty", bytes = "" }, { name = "invalid", bytes = test.invalid } }) do
            local candidate = backup
            it("does not publish or restart an " .. candidate.name .. " " .. test.name .. " restore", function()
                local S, fixture = begin()
                local svc = S[test.name]
                H.vfs_write(svc.config, test.new)
                H.vfs_write(svc.backup, candidate.bytes)
                assert.is_false(S.restore_backup(svc))
                assert_error(S.rollback(S.ops[test.name]))
                assert.equal(test.new, H.vfs_read(svc.config))
                assert.equal(candidate.bytes, H.vfs_read(svc.backup))
                assert.same({}, fixture.restarts)
                assert_no_publication(svc.config)
                assert_stages_cleaned()
            end)
        end

        it("validates and atomically restores " .. test.name .. " without overwriting its rollback copy", function()
            local S, fixture = begin()
            local svc = S[test.name]
            H.vfs_write(svc.config, test.invalid)
            H.vfs_write(svc.backup, test.old)
            assert.is_true(S.restore_backup(svc))
            assert.equal(test.old, H.vfs_read(svc.config))
            assert.equal(test.old, H.vfs_read(svc.backup))
            assert.same({}, fixture.restarts, "restore_backup alone must not restart")
            assert_stages_cleaned()
        end)

        it("retains " .. test.name .. " live bytes and backup if restore publication fails", function()
            local S, fixture = begin()
            local svc = S[test.name]
            H.vfs_write(svc.config, test.new)
            H.vfs_write(svc.backup, test.old)
            H.state().failures[svc.config] = { rename = true }
            assert.is_false(S.restore_backup(svc))
            assert.equal(test.new, H.vfs_read(svc.config))
            assert.equal(test.old, H.vfs_read(svc.backup))
            assert.same({}, fixture.restarts)
            assert_stages_cleaned()
        end)

        it("does not enter " .. test.name .. " mutation while another actor owns its lock", function()
            local S, fixture = begin({ execute = { { match = function() return true end, out = 0 } } })
            local svc = S[test.name]
            local lock = test.name == "singbox" and "/var/lock/podkop-fragment.lock" or
                "/var/lock/podkop-tweaker-" .. test.name .. ".lock"
            H.vfs_write(svc.config, test.old)
            H.vfs_write(svc.backup, test.old)
            H.vfs_mkdir(lock)
            assert_error(S.apply_service(svc, test.new))
            assert.is_false(S.restore_backup(svc))
            if test.name == "singbox" then assert.is_false(S.singbox_apply_checked(test.new, ".tmp-import")) end
            assert.equal(test.old, H.vfs_read(svc.config))
            assert.equal(test.old, H.vfs_read(svc.backup))
            assert.truthy(H.state().dirs[lock])
            assert.same({}, H.allocations())
            assert.same({}, fixture.restarts)
        end)
    end

    for _, operation in ipairs({ "open", "read", "close" }) do
        local fail = operation
        it("stops application on an existing source " .. fail .. " error without replacing the backup", function()
            local S, fixture = begin({ failures = { [CFG] = { [fail] = true, errno = 5 } } })
            H.vfs_write(CFG, SB_OLD)
            H.vfs_write(BAK, SB_OLD)
            assert_error(S.apply_service("singbox", SB_NEW))
            assert.equal(SB_OLD, H.vfs_read(CFG))
            assert.equal(SB_OLD, H.vfs_read(BAK))
            assert.same({}, fixture.restarts)
            assert_no_publication(CFG)
            assert_no_publication(BAK)
            assert_stages_cleaned()
        end)
    end

    for _, operation in ipairs({ "open", "read", "close" }) do
        local fail = operation
        it("does not restore or restart after a backup " .. fail .. " failure", function()
            local S, fixture = begin({ failures = { [BAK] = { [fail] = true, errno = 5 } } })
            H.vfs_write(CFG, SB_NEW)
            H.vfs_write(BAK, SB_OLD)
            assert.is_false(S.restore_backup(S.singbox))
            assert_error(S.rollback(S.ops.singbox))
            assert.equal(SB_NEW, H.vfs_read(CFG))
            assert.equal(SB_OLD, H.vfs_read(BAK))
            assert.same({}, fixture.restarts)
            assert_no_publication(CFG)
            assert_stages_cleaned()
        end)
    end

    it("honors backup=false without replacing the retained rollback copy", function()
        local S, fixture = begin()
        H.vfs_write(CFG, SB_NEW)
        H.vfs_write(BAK, SB_OLD)
        assert.is_true(S.apply_service("singbox", SB_FOREIGN, { backup = false, restart = false }).success)
        assert.equal(SB_FOREIGN, H.vfs_read(CFG))
        assert.equal(SB_OLD, H.vfs_read(BAK))
        assert_no_publication(BAK)
        assert.same({}, fixture.restarts)
        assert_stages_cleaned()
    end)

    it("stops before live publication/restart when backup staging cannot be flushed", function()
        local S, fixture = begin({ failures = { [BAK .. ".*"] = { close = true } } })
        H.vfs_write(CFG, SB_OLD)
        H.vfs_write(BAK, SB_OLD)
        assert_error(S.apply_service("singbox", SB_NEW))
        assert.equal(SB_OLD, H.vfs_read(CFG))
        assert.equal(SB_OLD, H.vfs_read(BAK))
        assert.same({}, fixture.restarts)
        assert_no_publication(CFG)
        assert_no_publication(BAK)
        assert_stages_cleaned()
    end)

    it("distinguishes unchanged Save from an explicit same-bytes import", function()
        local S, fixture = begin()
        H.vfs_write(S.podkop.config, PODKOP_OLD)
        local unchanged = S.apply_service("podkop", PODKOP_OLD, { skip_unchanged = true })
        assert.is_true(unchanged.success)
        assert.is_true(unchanged.unchanged)
        assert.is_nil(H.vfs_read(S.podkop.backup))
        assert.same({}, fixture.restarts)
        assert_no_publication(S.podkop.config)
        local imported = S.apply_service("podkop", PODKOP_OLD)
        assert.is_true(imported.success)
        assert.is_true(imported.restarting)
        assert.equal(PODKOP_OLD, H.vfs_read(S.podkop.backup))
        assert.equal(1, #fixture.restarts)
        assert_stages_cleaned()
    end)

    it("records applied disk bytes and full restart failure without replay or file rollback", function()
        local diagnostics = string.rep("restart diagnostic\n", 1000) .. "service failed"
        local S, fixture = begin({ restart_output = checked_output(diagnostics, 19) })
        H.vfs_write(S.podkop.config, PODKOP_OLD)
        local response = S.apply_service("podkop", PODKOP_NEW)
        assert_error(response)
        assert.is_true(response.applied)
        assert.equal(diagnostics, response.details)
        assert.equal(PODKOP_NEW, H.vfs_read(S.podkop.config))
        assert.equal(PODKOP_OLD, H.vfs_read(S.podkop.backup))
        assert.equal(1, #fixture.restarts)
        assert_stages_cleaned()
    end)
end)
