-- api_stubby_spec | v1.1.0 | 17.10.2026 | Owned init repair and checked service/partial-application contracts

package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path

local H = require("pt_harness")
local CFG = "/etc/config/stubby"
local BAK = CFG .. ".auto-backup"
local INIT = "/etc/init.d/stubby"
local VALID = "config stubby 'global'\n\toption manual '0'\n"
local OTHER = "config stubby 'global'\n\toption manual '1'\n"
local SCRIPT = "#!/bin/sh\nstart_service() {\n\tprocd_set_param user stubby\n\tPROG=/usr/sbin/stubby\n}\n"
local FIXED = SCRIPT:gsub("procd_set_param user stubby", "procd_set_param user root")
local SERVICE_COMMANDS = {
    restart = "/etc/init.d/stubby restart 2>&1",
    start = "'/etc/init.d/stubby' start", stop = "'/etc/init.d/stubby' stop",
    enable = "/etc/init.d/stubby enable", disable = "/etc/init.d/stubby disable"
}

local function service_reply(action, output)
    local expected = assert(SERVICE_COMMANDS[action])
    return { match = function(cmd)
        return cmd == require("podkop-tweaker.services").checked_command(expected)
    end, out = output }
end

local function pid_reply(output)
    return { match = function(cmd)
        return cmd:find("pidof", 1, true) and cmd:find("stubby", 1, true)
    end, out = output }
end

local function begin_stubby(opts)
    opts = opts or {}
    if opts.strict == nil then opts.strict = true end
    opts.sys = opts.sys or {}
    for _, action in ipairs({ "restart", "start", "stop", "enable", "disable" }) do
        table.insert(opts.sys, service_reply(action, "\nPT_EXIT:0\n"))
    end
    table.insert(opts.sys, pid_reply("\nPT_EXIT:1\n"))
    table.insert(opts.sys, { match = "sh -n ", out = "\nPT_EXIT:0\n" })
    table.insert(opts.sys, { match = "chmod 755 ", out = "\nPT_EXIT:0\n" })
    table.insert(opts.sys, { match = "for link in /etc/rc.d/S*stubby", out = "\nPT_EXIT:0\n" })
    H.begin(opts)
    return H.reload("podkop-tweaker.api_stubby")
end

local function commands_containing(text)
    local result = {}
    for _, cmd in ipairs(H.exec_cmds()) do
        if cmd:find(text, 1, true) then result[#result + 1] = cmd end
    end
    return result
end

local function assert_restart(resp, running, instance)
    assert.is_true(resp.success)
    assert.is_true(resp.restarting)
    assert.is_true(resp.verification_required)
    assert.equal(running or false, resp.previous_running)
    assert.is_true(resp.previous_identity_known)
    assert.equal(instance, resp.previous_instance)
end

local function assert_unpublished(source)
    assert.equal(source or SCRIPT, H.vfs_read(INIT))
    assert.equal(0, #commands_containing("/etc/init.d/stubby restart"))
    for path in pairs(H.state().vfs) do
        if path:sub(1, #INIT + 9) == INIT .. ".tmp-fix." then
            assert.equal(INIT .. ".tmp-fix.foreign", path, "owned stages must be discarded")
        end
    end
end

after_each(function() H.finish() end)

describe("api_stubby shared service application", function()
    it("retains Save/Import validation messages", function()
        local STB = begin_stubby()
        assert.same({ error = "Configuration is empty" }, STB.save_config(""))
        assert.same({ error = "Empty content" }, STB.import_config(""))
        assert.same({ error = "Invalid UCI format: no 'config' declarations found" }, STB.save_config("junk"))
        assert.same({ error = "Invalid UCI format: no 'config' declarations found" }, STB.import_config("junk"))
        assert.equal(0, #commands_containing("/etc/init.d/stubby restart"))
    end)

    it("Save skips unchanged content while Import remains an explicit apply", function()
        local STB = begin_stubby()
        H.vfs_write(CFG, VALID)
        assert.is_true(STB.save_config(VALID).unchanged)
        assert.is_nil(H.vfs_read(BAK))
        assert.equal(0, #commands_containing("/etc/init.d/stubby restart"))
        assert_restart(STB.import_config(VALID))
        assert.equal(1, #commands_containing("/etc/init.d/stubby restart"))
    end)

    it("accepts first-install Save and backs up usable previous content on the next import", function()
        local STB = begin_stubby()
        assert_restart(STB.save_config(VALID))
        assert.equal(VALID, H.vfs_read(CFG))
        assert.is_nil(H.vfs_read(BAK))
        assert_restart(STB.import_config(OTHER))
        assert.equal(VALID, H.vfs_read(BAK))
        assert.equal(OTHER, H.vfs_read(CFG))
    end)

    it("propagates a failed backup close without publishing or restarting", function()
        local STB = begin_stubby({ failures = { [BAK .. ".*"] = { close = true } } })
        H.vfs_write(CFG, OTHER)
        H.vfs_write(BAK, VALID)
        local r = STB.import_config(VALID)
        assert.truthy(r.error)
        assert.falsy(r.success)
        assert.falsy(r.applied)
        assert.equal(OTHER, H.vfs_read(CFG))
        assert.equal(VALID, H.vfs_read(BAK))
        assert.equal(0, #commands_containing("/etc/init.d/stubby restart"))
    end)

    it("keeps disk bytes and restart evidence on a quiet nonzero restart", function()
        local STB = begin_stubby({ sys = {
            service_reply("restart", "\nPT_EXIT:11\n"),
            pid_reply("123\nPT_EXIT:0\n")
        } })
        H.vfs_write("/proc/123/stat", "123 (stubby) S " .. string.rep("0 ", 18) .. "200\n")
        H.vfs_write(CFG, OTHER)
        local r = STB.save_config(VALID)
        assert.is_false(r.success)
        assert.is_true(r.applied)
        assert.is_true(r.verification_required)
        assert.is_true(r.previous_running)
        assert.is_true(r.previous_identity_known)
        assert.equal("123:200", r.previous_instance)
        assert.truthy(r.error)
        assert.equal(VALID, H.vfs_read(CFG))
        assert.equal(OTHER, H.vfs_read(BAK))
        assert.equal(1, #commands_containing("/etc/init.d/stubby restart"))
    end)

    it("forwards the entire shared response for Save, Import and Template", function()
        local STB = begin_stubby()
        local SRV = require("podkop-tweaker.services")
        local result = { success = false, applied = true, error = "restart failed", details = "all output\n",
            verification_required = true, previous_running = true, previous_identity_known = true,
            previous_instance = "123:200", warning = "previous backup retained" }
        local calls = {}
        SRV.apply_service = function(svc, content, options)
            assert.equal(SRV.stubby, svc)
            calls[#calls + 1] = { content = content, options = options or {} }
            return result
        end
        assert.equal(result, STB.save_config(VALID))
        assert.equal(result, STB.import_config(VALID))
        assert.equal(result, STB.apply_recommended())
        assert.is_true(calls[1].options.skip_unchanged)
        assert.falsy(calls[2].options.skip_unchanged)
        assert.falsy(calls[3].options.skip_unchanged)
        assert.is_true(require("podkop-tweaker.lib").validate_uci_config(calls[3].content))
    end)
end)

describe("api_stubby service status/toggle/rollback", function()
    it("reports PID plus start-time identity without equating the old process to readiness", function()
        local STB = begin_stubby({ sys = { pid_reply("123\nPT_EXIT:0\n") } })
        H.vfs_write("/proc/123/stat", "123 (stubby) S " .. string.rep("0 ", 18) .. "200\n")
        local status = STB.service_status()
        assert.is_true(status.running)
        assert.equal("123", status.pid)
        assert.equal("123:200", status.instance)
        H.vfs_write(CFG, OTHER)
        assert_restart(STB.save_config(VALID), true, "123:200")
    end)

    it("distinguishes known absence, failed query and unreadable process identity", function()
        local STB = begin_stubby()
        assert.is_false(STB.service_status().running)
        H.finish()
        STB = begin_stubby({ sys = { pid_reply("\nPT_EXIT:2\n") } })
        local unknown = STB.service_status()
        assert.truthy(unknown.error)
        assert.is_nil(unknown.running)
        H.finish()
        STB = begin_stubby({ sys = { pid_reply("123\nPT_EXIT:0\n") } })
        local no_identity = STB.service_status()
        assert.is_true(no_identity.running)
        assert.is_nil(no_identity.instance)
        assert.truthy(no_identity.identity_error)
    end)

    it("does not invent previous process facts when the pre-restart query fails", function()
        local STB = begin_stubby({ sys = { pid_reply("query failed\n\nPT_EXIT:2\n") } })
        H.vfs_write(CFG, OTHER)
        local r = STB.save_config(VALID)
        assert.is_true(r.success)
        assert.is_true(r.applied)
        assert.is_true(r.restarting)
        assert.is_true(r.verification_required)
        assert.is_false(r.previous_identity_known)
        assert.is_nil(r.previous_running)
        assert.is_nil(r.previous_instance)
        assert.equal(VALID, H.vfs_read(CFG))
        assert.equal(1, #commands_containing(SERVICE_COMMANDS.restart))
    end)

    it("validates toggles and never hides nonzero command output", function()
        local details = string.rep("start failure\n", 100)
        local STB = begin_stubby({ sys = { service_reply("start", details .. "\nPT_EXIT:7\n") } })
        assert.same({ success = false, error = "Invalid action" }, STB.service_toggle("restart"))
        local failed = STB.service_toggle("start")
        assert.is_false(failed.success)
        assert.truthy(failed.error)
        assert.equal(details, failed.details)
        assert.equal(1, #commands_containing(SERVICE_COMMANDS.start))
        local stopped = STB.service_toggle("stop")
        assert.is_true(stopped.success)
        assert.is_false(stopped.running)
    end)

    it("restores only a validated backup and forwards restart metadata", function()
        local STB = begin_stubby()
        assert.equal("Backup file not found", STB.rollback().error)
        H.vfs_write(BAK, "invalid backup")
        H.vfs_write(CFG, OTHER)
        assert.truthy(STB.rollback().error)
        assert.equal(OTHER, H.vfs_read(CFG))
        assert.equal(0, #commands_containing("/etc/init.d/stubby restart"))
        H.vfs_write(BAK, VALID)
        assert_restart(STB.rollback())
        assert.equal(VALID, H.vfs_read(CFG))
        assert.equal(VALID, H.vfs_read(BAK))
    end)
end)

describe("api_stubby.chain_info", function()
    local function read_chain(stubby, podkop)
        return begin_stubby({ uci = { stubby = stubby or {}, podkop = podkop or {} } }).chain_info()
    end

    it("preserves string/list listener values", function()
        assert.equal("127.0.0.53@5353", read_chain({ H.sec("global", "stubby", { listen_address = "127.0.0.53@5353" }) }).stubby_listen)
        assert.equal("127.0.0.1@53, ::1@53", read_chain({ H.sec("global", "stubby", { listen_address = { "127.0.0.1@53", "::1@53" } }) }).stubby_listen)
    end)

    it("maps resolvers and existing defaults; last configured Podkop DNS remains authoritative", function()
        local r = read_chain({
            H.sec("r1", "resolver", { address = "1.1.1.1", tls_auth_name = "cf" }),
            H.sec("r2", "resolver", { address = "9.9.9.9", tls_port = "8553" }), H.sec("r3", "resolver", {})
        }, { H.sec("a", "section", { dns_server = "1.1.1.1" }), H.sec("b", "section", { dns_server = "9.9.9.9" }) })
        assert.equal("", r.stubby_listen)
        assert.same({
            { address = "1.1.1.1", tls_auth_name = "cf", tls_port = "853" },
            { address = "9.9.9.9", tls_auth_name = "", tls_port = "8553" },
            { address = "", tls_auth_name = "", tls_port = "853" }
        }, r.resolvers)
        assert.equal("9.9.9.9", r.podkop_dns)
    end)
end)

describe("api_stubby.init_check/init_fix IO3", function()
    it("retains the detection contract without changing deferred listener detection", function()
        local STB = begin_stubby()
        assert.same({ status = "not_installed" }, STB.init_check())
        assert.equal("Init script not found", STB.init_fix().error)
        H.vfs_write(INIT, SCRIPT)
        assert.same({ status = "needs_fix" }, STB.init_check())
        H.vfs_write(INIT, FIXED)
        assert.same({ status = "fixed" }, STB.init_check())
        assert.same({ success = true, message = "Already fixed" }, STB.init_fix())
        assert.equal(0, #commands_containing("/etc/init.d/stubby restart"))
    end)

    it("does not label an empty init script fixed", function()
        local STB = begin_stubby()
        H.vfs_write(INIT, " \n\t")
        assert.equal("Init script is empty", STB.init_check().error)
        assert.equal("Init script is empty", STB.init_fix().error)
        assert_unpublished(" \n\t")
    end)

    it("does not steal a held Stubby resource or stage a repair while it is busy", function()
        local STB = begin_stubby()
        H.vfs_write(INIT, SCRIPT)
        H.vfs_mkdir("/var/lock/podkop-tweaker-stubby.lock")
        local r = STB.init_fix()
        assert.is_false(r.success)
        assert.truthy(r.error)
        assert.is_true(H.vfs_exists("/var/lock/podkop-tweaker-stubby.lock"))
        assert.equal(0, #H.stage_paths(INIT .. ".tmp-fix.*"))
        assert_unpublished()
    end)

    for _, operation in ipairs({ "open", "read", "close" }) do
        it("does not treat source " .. operation .. " failure as absence or fixed state", function()
            local STB = begin_stubby({ failures = { [INIT] = { [operation] = true, errno = 13 } } })
            H.vfs_write(INIT, SCRIPT)
            local check, fix = STB.init_check(), STB.init_fix()
            assert.truthy(check.error)
            assert.is_nil(check.status)
            assert.truthy(fix.error)
            assert.truthy(fix.details)
            assert_unpublished()
        end)
    end

    it("publishes the exact checked script from a unique adjacent stage and requests a checked restart", function()
        local STB = begin_stubby()
        H.vfs_write(INIT, SCRIPT)
        assert_restart(STB.init_fix())
        assert.equal(FIXED, H.vfs_read(INIT))
        local checks = commands_containing("sh -n ")
        assert.equal(1, #checks)
        local stage = checks[1]:match("sh %-n '([^']+)'")
        assert.truthy(stage)
        assert.matches("^/etc/init%.d/stubby%.tmp%-fix%.", stage)
        assert.is_nil(H.vfs_read(stage))
        assert.is_true(#commands_containing("chmod 755 '" .. stage .. "'") >= 1)
        assert.equal(1, #commands_containing("/etc/init.d/stubby restart"))
    end)

    for _, case in ipairs({
        { name = "partial write", failure = { write = true, partial = 11 } },
        { name = "close", failure = { close = true } }
    }) do
        it("retains live bytes on an actual " .. case.name .. " failure and cleans only its owned stage", function()
            local STB = begin_stubby({ failures = { [INIT .. ".tmp-fix.*"] = case.failure } })
            H.vfs_write(INIT, SCRIPT)
            H.vfs_write(INIT .. ".tmp-fix.foreign", "other invocation")
            local r = STB.init_fix()
            assert.is_false(r.success)
            assert.truthy(r.error)
            assert.truthy(r.details)
            assert.falsy(r.applied)
            local writes = 0
            for _, call in ipairs(H.state().io_log) do
                if call.operation == "write" and call.path:find(INIT .. ".tmp-fix.", 1, true) == 1 then
                    writes = writes + 1
                    assert.not_equal(INIT .. ".tmp-fix.foreign", call.path)
                end
            end
            assert.equal(1, writes, "exercise the allocated stage's real VFS write, not a helper stub")
            assert.equal("other invocation", H.vfs_read(INIT .. ".tmp-fix.foreign"))
            assert.equal(0, #commands_containing("sh -n "))
            assert_unpublished()
        end)
    end

    for _, case in ipairs({
        { name = "syntax", command = "sh -n ", output = string.rep("shell syntax context\n", 100) .. "\nPT_EXIT:2\n" },
        { name = "quiet syntax", command = "sh -n ", output = "\nPT_EXIT:2\n" },
        { name = "missing exit evidence", command = "sh -n ", output = "" },
        { name = "chmod", command = "chmod 755 ", output = "permission denied\n\nPT_EXIT:1\n" }
    }) do
        it("does not publish or restart after " .. case.name .. " failure", function()
            local STB = begin_stubby({ sys = { { match = case.command, out = case.output } } })
            H.vfs_write(INIT, SCRIPT)
            local r = STB.init_fix()
            assert.is_false(r.success)
            assert.truthy(r.error)
            assert.falsy(r.applied)
            if case.name == "syntax" then assert.equal(string.rep("shell syntax context\n", 100), r.details) end
            assert_unpublished()
        end)
    end

    it("keeps a concurrent source edit made while the staged script is checked", function()
        local changed = SCRIPT .. "# administrator change\n"
        local STB = begin_stubby({ sys = { { match = "sh -n ", out = function()
            H.vfs_write(INIT, changed)
            return "\nPT_EXIT:0\n"
        end } } })
        H.vfs_write(INIT, SCRIPT)
        local r = STB.init_fix()
        assert.equal("Init script changed during repair", r.error)
        assert_unpublished(changed)
    end)

    it("rejects a stage whose bytes changed after validation", function()
        local STB = begin_stubby({ sys = { { match = "chmod 755 ", out = function(cmd)
            local stage = cmd:match("chmod 755 '([^']+)'")
            assert.truthy(stage)
            H.vfs_write(stage, "truncated")
            return "\nPT_EXIT:0\n"
        end } } })
        H.vfs_write(INIT, SCRIPT)
        assert.truthy(STB.init_fix().error)
        assert_unpublished()
    end)

    it("checks publication failure and preserves the original init", function()
        local STB = begin_stubby({ failures = { [INIT] = { rename = true } } })
        H.vfs_write(INIT, SCRIPT)
        local r = STB.init_fix()
        assert.equal("Cannot apply init script fix", r.error)
        assert.truthy(r.details)
        assert_unpublished()
    end)

    it("reports a checked restart failure as applied init bytes, with complete diagnostics", function()
        local details = string.rep("restart refused\n", 100)
        local STB = begin_stubby({ sys = { service_reply("restart", details .. "\nPT_EXIT:9\n") } })
        H.vfs_write(INIT, SCRIPT)
        local r = STB.init_fix()
        assert.is_false(r.success)
        assert.is_true(r.applied)
        assert.truthy(r.error)
        assert.equal(details, r.details)
        assert.equal(FIXED, H.vfs_read(INIT))
        assert.equal(1, #commands_containing("/etc/init.d/stubby restart"))
    end)

    it("surfaces the resource-release partial-result contract", function()
        local STB = begin_stubby()
        local SRV = require("podkop-tweaker.services")
        local with_lock = SRV.with_lock
        SRV.with_lock = function(key, fn)
            local result = with_lock(key, fn)
            assert.is_true(result.success)
            return nil, "Cannot release stubby lock", true
        end
        H.vfs_write(INIT, SCRIPT)
        local r = STB.init_fix()
        assert.is_false(r.success)
        assert.equal("Cannot release stubby lock", r.error)
        assert.is_true(r.applied)
        assert.is_true(r.unknown)
        assert.is_true(r.verification_required)
        assert.is_true(r.previous_identity_known)
        assert.equal(FIXED, H.vfs_read(INIT))
    end)

    it("keeps failed-stage cleanup diagnostics together with the complete syntax failure", function()
        local details = string.rep("syntax failure\n", 100)
        local STB = begin_stubby({ sys = { { match = "sh -n ", out = details .. "\nPT_EXIT:2\n" } },
            failures = { [INIT .. ".tmp-fix.*"] = { remove = true } } })
        H.vfs_write(INIT, SCRIPT)
        local r = STB.init_fix()
        assert.is_false(r.success)
        assert.is_true(r.cleanup_failed)
        assert.falsy(r.applied)
        assert.equal(details, r.details:sub(1, #details))
        assert.truthy(r.details:find("Injected remove failure", 1, true))
        assert.equal(SCRIPT, H.vfs_read(INIT))
        local stage = H.last_stage(INIT .. ".tmp-fix.*")
        assert.equal(FIXED, H.vfs_read(stage))
        assert.equal(0, #commands_containing("/etc/init.d/stubby restart"))
        H.state().failures[INIT .. ".tmp-fix.*"] = nil
        assert.is_true(require("podkop-tweaker.services").discard_stage(stage))
    end)

    it("does not label an unapplied syntax failure applied when lock release fails", function()
        local STB = begin_stubby({ sys = { { match = "sh -n ", out = "syntax error\n\nPT_EXIT:2\n" } },
            failures = { ["/var/lock/podkop-tweaker-stubby.lock"] = { rmdir = true } } })
        H.vfs_write(INIT, SCRIPT)
        local r = STB.init_fix()
        assert.is_false(r.success)
        assert.is_true(r.unknown)
        assert.falsy(r.applied)
        assert.truthy(r.details:find("Init script syntax check failed\nsyntax error\n", 1, true))
        assert_unpublished()
    end)
end)

describe("api_stubby.apply_recommended", function()
    it("supports first installation and preserves the selected six-endpoint template", function()
        local STB = begin_stubby()
        assert_restart(STB.apply_recommended())
        assert.is_nil(H.vfs_read(BAK))
        local content = H.vfs_read(CFG)
        for _, expected in ipairs({ "config stubby 'global'", "option round_robin_upstreams '1'", "option log_level '3'",
            "option idle_timeout '30000'", "127.0.0.53@53", "1.1.1.1", "1.0.0.1", "9.9.9.9", "149.112.112.112", "185.222.222.222", "45.11.45.11" }) do
            assert.truthy(content:find(expected, 1, true))
        end
        local _, count = content:gsub("option tls_auth_name 'dot%.sb'", "")
        assert.equal(2, count)
        assert.falsy(content:find("option tls_auth_name 'dns.sb'", 1, true))
        assert.is_true(require("podkop-tweaker.lib").validate_uci_config(content))
        assert_restart(STB.apply_recommended())
        assert.equal(content, H.vfs_read(BAK))
    end)
end)

describe("api_stubby.autostart", function()
    it("uses checked observations for both present and absent rc links", function()
        local STB = begin_stubby({ sys = { { match = "for link in /etc/rc.d/S*stubby", out = "/etc/rc.d/S99stubby\n\nPT_EXIT:0\n" } } })
        assert.same({ enabled = true }, STB.autostart())
        assert.same({ success = true, enabled = true }, STB.autostart_toggle("enable"))
        H.finish()
        STB = begin_stubby()
        assert.same({ enabled = false }, STB.autostart())
        assert.same({ success = true, enabled = false }, STB.autostart_toggle("disable"))
    end)

    it("rejects invalid actions and quiet nonzero autostart commands", function()
        local STB = begin_stubby({ sys = { service_reply("enable", "\nPT_EXIT:1\n") } })
        assert.same({ error = "Invalid action" }, STB.autostart_toggle("up"))
        local r = STB.autostart_toggle("enable")
        assert.is_false(r.success)
        assert.truthy(r.error)
        assert.is_nil(r.enabled)
    end)

    it("keeps failed observation Unknown and never confirms unchanged state", function()
        local STB = begin_stubby({ sys = { { match = "for link in /etc/rc.d/S*stubby", out = "cannot inspect rc.d\n\nPT_EXIT:2\n" } } })
        assert.truthy(STB.autostart().error)
        local failed = STB.autostart_toggle("enable")
        assert.is_false(failed.success)
        assert.is_nil(failed.enabled)
        H.finish()
        STB = begin_stubby()
        local unchanged = STB.autostart_toggle("enable")
        assert.is_false(unchanged.success)
        assert.is_false(unchanged.enabled)
    end)
end)
