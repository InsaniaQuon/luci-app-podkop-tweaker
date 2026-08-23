-- api_stubby_spec | v1.0.0 | 23.08.2026 | Max-coverage specs for V2 pure handlers of api_stubby

package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path

local H = require("pt_harness")

local CFG = "/etc/config/stubby"
local BAK = "/etc/config/stubby.auto-backup"
local INIT = "/etc/init.d/stubby"

local VALID = "config stubby 'global'\n\toption manual '0'\n"
local OTHER = "config stubby 'global'\n\toption manual '1'\n"
local OLD_GOOD = "old-good-config\n"

after_each(function()
    H.finish()
end)

describe("api_stubby.save_config", function()
    local function mod()
        return H.reload("podkop-tweaker.api_stubby")
    end

    it("empty content -> validation error", function()
        H.begin({})
        assert.same({ error = "Configuration is empty" }, mod().save_config(""))
    end)

    it("invalid uci -> syntax error from validator", function()
        H.begin({})
        assert.same({ error = "Invalid UCI format: no 'config' declarations found" },
            mod().save_config("hello world"))
    end)

    it("identical content -> unchanged, no backup/restart", function()
        H.begin({})
        H.vfs_write(CFG, OTHER)
        local resp = mod().save_config(OTHER)
        assert.same({ success = true, unchanged = true }, resp)
        assert.falsy(H.vfs_exists(BAK))
        assert.equal(0, #H.exec_cmds())
    end)

    it("first save: no prior file -> no backup step, write+restart", function()
        H.begin({})
        local resp = mod().save_config(VALID)
        assert.same({ success = true, restarting = true }, resp)
        assert.equal(VALID, H.vfs_read(CFG))
        assert.falsy(H.vfs_exists(BAK))
        assert.equal("/etc/init.d/stubby restart 2>&1", H.exec_cmds()[1])
        assert.equal(1, #H.exec_cmds())
    end)

    it("update: existing file backed up before overwrite", function()
        H.begin({})
        H.vfs_write(CFG, OTHER)
        local resp = mod().save_config(VALID)
        assert.is_true(resp.restarting)
        assert.equal(OTHER, H.vfs_read(BAK))
        assert.equal(VALID, H.vfs_read(CFG))
    end)

    it("backup failure -> exact error, disk untouched, no restart", function()
        H.begin({})
        H.vfs_write(CFG, OTHER)
        local SRV = require("podkop-tweaker.services")
        SRV.backup_current = function() return false end
        local resp = mod().save_config(VALID)
        assert.same({ error = "Cannot create backup" }, resp)
        assert.equal(OTHER, H.vfs_read(CFG))
        assert.equal(0, #H.exec_cmds())
    end)

    it("write failure -> error passthrough", function()
        H.begin({})
        H.vfs_write(CFG, OTHER)
        local SRV = require("podkop-tweaker.services")
        SRV.write_file_atomic = function() return false, "boom" end
        assert.same({ error = "boom" }, mod().save_config(VALID))
    end)
end)

describe("api_stubby.service_status/toggle", function()
    it("status reflects pid presence", function()
        H.begin({ sys = { { match = "pidof stubby", out = "123\n" } } })
        assert.same({ running = true, pid = "123" },
            H.reload("podkop-tweaker.api_stubby").service_status())
        H.finish()

        H.begin({ sys = { { match = "pidof stubby", out = "" } } })
        assert.same({ running = false, pid = nil },
            H.reload("podkop-tweaker.api_stubby").service_status())
    end)

    it("invalid action rejected without exec", function()
        H.begin({})
        local STB = H.reload("podkop-tweaker.api_stubby")
        assert.same({ error = "Invalid action" }, STB.service_toggle("restart"))
        assert.equal(0, #H.exec_cmds())
    end)

    it("start -> running true; stop -> running false", function()
        H.begin({
            sys = {
                { match = "pidof stubby", out = "5\n" }
            }
        })
        local STB = H.reload("podkop-tweaker.api_stubby")
        local r1 = STB.service_toggle("start")
        assert.same({ success = true, running = true }, r1)
        assert.truthy(H.exec_cmds()[1]:find("^/etc/init%.d/stubby start"))

        H.finish()
        H.begin({ sys = { { match = "pidof stubby", out = "" } } })
        local STB2 = H.reload("podkop-tweaker.api_stubby")
        assert.same({ success = true, running = false }, STB2.service_toggle("stop"))
        assert.truthy(H.exec_cmds()[1]:find("^/etc/init%.d/stubby stop"))
    end)
end)

describe("api_stubby.rollback", function()
    it("missing backup -> friendly error", function()
        H.begin({})
        assert.same({ error = "Backup file not found" },
            H.reload("podkop-tweaker.api_stubby").rollback())
    end)

    it("restores content and restarts", function()
        H.begin({})
        H.vfs_write(BAK, OLD_GOOD)
        H.vfs_write(CFG, "current-broken\n")

        local resp = H.reload("podkop-tweaker.api_stubby").rollback()
        assert.same({ success = true, restarting = true }, resp)
        assert.equal(OLD_GOOD, H.vfs_read(CFG))
        assert.equal("/etc/init.d/stubby restart 2>&1", H.exec_cmds()[1])
    end)
end)

describe("api_stubby.chain_info", function()
    local function begin_ci(stubby_secs, podkop_secs)
        H.begin({
            uci = { stubby = stubby_secs or {}, podkop = podkop_secs or {} }
        })
        return H.reload("podkop-tweaker.api_stubby").chain_info()
    end

    it("string listen_address passes through verbatim", function()
        local r = begin_ci({ H.sec("global", "stubby", { listen_address = "127.0.0.53@5353" }) })
        assert.equal("127.0.0.53@5353", r.stubby_listen)
    end)

    it("list listen_address joined with comma", function()
        local r = begin_ci({ H.sec("global", "stubby",
            { listen_address = { "127.0.0.1@53", "::1@53" } }) })
        assert.equal("127.0.0.1@53, ::1@53", r.stubby_listen)
    end)

    it("absent global -> empty listener; resolvers mapped with defaults", function()
        local r = begin_ci({
            H.sec("r1", "resolver", { address = "1.1.1.1", tls_auth_name = "cf" }),
            H.sec("r2", "resolver", { address = "9.9.9.9", tls_port = "8553" }),
            H.sec("r3", "resolver", {})
        }, {})
        assert.equal("", r.stubby_listen)
        assert.same({
            { address = "1.1.1.1", tls_auth_name = "cf", tls_port = "853" },
            { address = "9.9.9.9", tls_auth_name = "", tls_port = "8553" },
            { address = "", tls_auth_name = "", tls_port = "853" }
        }, r.resolvers)
        assert.equal("", r.podkop_dns)
    end)

    it("podkop_dns takes last section value", function()
        local r = begin_ci({}, {
            H.sec("a", "section", { dns_server = "1.1.1.1" }),
            H.sec("b", "section", { dns_server = "9.9.9.9" })
        })
        assert.equal("9.9.9.9", r.podkop_dns)
    end)
end)

describe("api_stubby.init_check/init_fix", function()
    local MARKER = "procd_set_param user stubby"

    it("check: not_installed / needs_fix / fixed", function()
        H.begin({})
        assert.same({ status = "not_installed" },
            H.reload("podkop-tweaker.api_stubby").init_check())

        H.finish()
        H.begin({})
        H.vfs_write(INIT, "#!/bin/sh\n" .. MARKER .. "\nexit 0\n")
        assert.same({ status = "needs_fix" },
            H.reload("podkop-tweaker.api_stubby").init_check())

        H.finish()
        H.begin({})
        H.vfs_write(INIT, "#!/bin/sh\nprocd_set_param user root\n")
        assert.same({ status = "fixed" },
            H.reload("podkop-tweaker.api_stubby").init_check())
    end)

    it("fix: missing script -> error", function()
        H.begin({})
        assert.same({ error = "Init script not found" },
            H.reload("podkop-tweaker.api_stubby").init_fix())
    end)

    it("fix: already fixed -> message without side effects", function()
        H.begin({})
        H.vfs_write(INIT, "#!/bin/sh\nprocd_set_param user root\n")
        local STB = H.reload("podkop-tweaker.api_stubby")
        assert.same({ success = true, message = "Already fixed" }, STB.init_fix())
        assert.equal(0, #H.exec_cmds())
    end)

    it("fix: rewrites user stubby->root into tmp, logs chmod+mv and restart", function()
        H.begin({})
        H.vfs_write(INIT, "#!/bin/sh\n" .. MARKER .. "\nPROG=/usr/sbin/stubby\n")
        local STB = H.reload("podkop-tweaker.api_stubby")
        local resp = STB.init_fix()
        assert.same({ success = true }, resp)
        -- sys.exec is stubbed: the mv itself is shell territory; verify tmp artifact + commands
        local tmp = H.vfs_read(INIT .. ".tmp-fix")
        assert.truthy(tmp)
        assert.falsy(tmp:find(MARKER, 1, true))
        assert.truthy(tmp:find("procd_set_param user root", 1, true))
        assert.truthy(tmp:find("PROG=", 1, true))
        assert.truthy(H.exec_cmds()[1]:find("^chmod %+x /etc/init%.d/stubby%.tmp%-fix && mv "))
        assert.equal("/etc/init.d/stubby restart 2>&1", H.exec_cmds()[2])
    end)
end)

describe("api_stubby.import_config", function()
    local function mod()
        return H.reload("podkop-tweaker.api_stubby")
    end

    it("empty -> exact error", function()
        H.begin({})
        assert.same({ error = "Empty content" }, mod().import_config(""))
    end)

    it("invalid uci -> validator error", function()
        H.begin({})
        assert.same({ error = "Invalid UCI format: no 'config' declarations found" },
            mod().import_config("junk"))
    end)

    it("backup failure -> exact error", function()
        H.begin({})
        H.vfs_write(CFG, OTHER)
        local S = require("pt-subs-lib")
        S.backup_stubby_config = function() return false end
        assert.same({ error = "Cannot create backup" }, mod().import_config(VALID))
    end)

    it("happy: sub-backup created, content replaced, restart", function()
        H.begin({})
        H.vfs_write(CFG, OTHER)
        local resp = mod().import_config(VALID)
        assert.same({ success = true, restarting = true }, resp)
        assert.equal(OTHER, H.vfs_read(BAK))
        assert.equal(VALID, H.vfs_read(CFG))
        assert.equal("/etc/init.d/stubby restart 2>&1", H.exec_cmds()[1])
    end)

    it("write failure passthrough", function()
        H.begin({})
        H.vfs_write(CFG, OTHER)
        local SRV = require("podkop-tweaker.services")
        SRV.write_file_atomic = function() return false, "wf" end
        assert.same({ error = "wf" }, mod().import_config(VALID))
    end)
end)

describe("api_stubby.apply_recommended", function()
    local function mod()
        return H.reload("podkop-tweaker.api_stubby")
    end

    it("no existing config -> backup fails first", function()
        H.begin({})
        assert.same({ error = "Cannot create backup" }, mod().apply_recommended())
    end)

    it("happy: template written exactly, backup kept, restart", function()
        H.begin({})
        H.vfs_write(CFG, OTHER)
        local resp = mod().apply_recommended()
        assert.same({ success = true, restarting = true }, resp)
        local c = H.vfs_read(CFG)
        assert.truthy(c:find("config stubby 'global'", 1, true))
        assert.truthy(c:find("option round_robin_upstreams '1'", 1, true))
        assert.truthy(c:find("9.9.9.9", 1, true))
        assert.truthy(c:find("149.112.112.112", 1, true))
        assert.truthy(c:find("127.0.0.53@53", 1, true))
        assert.equal(OTHER, H.vfs_read(BAK))
        assert.equal("/etc/init.d/stubby restart 2>&1", H.exec_cmds()[1])
    end)

    it("write failure passthrough", function()
        H.begin({})
        H.vfs_write(CFG, OTHER)
        local SRV = require("podkop-tweaker.services")
        SRV.write_file_atomic = function() return false, "x" end
        assert.same({ error = "x" }, mod().apply_recommended())
    end)
end)

describe("api_stubby.autostart", function()
    it("enabled when rc link listed", function()
        H.begin({ sys = { { match = "S*stubby", out = "/etc/rc.d/S99stubby\n" } } })
        assert.same({ enabled = true }, H.reload("podkop-tweaker.api_stubby").autostart())
    end)

    it("disabled when ls empty", function()
        H.begin({})
        assert.same({ enabled = false }, H.reload("podkop-tweaker.api_stubby").autostart())
    end)
end)

describe("api_stubby.autostart_toggle", function()
    it("invalid action rejected", function()
        H.begin({})
        local STB = H.reload("podkop-tweaker.api_stubby")
        assert.same({ error = "Invalid action" }, STB.autostart_toggle("up"))
        assert.equal(0, #H.exec_cmds())
    end)

    it("enable reports enabled state after exec", function()
        H.begin({ sys = { { match = "S*stubby", out = "/etc/rc.d/S99stubby\n" } } })
        local STB = H.reload("podkop-tweaker.api_stubby")
        local r = STB.autostart_toggle("enable")
        assert.same({ success = true, enabled = true }, r)
        assert.truthy(H.exec_cmds()[1]:find("^/etc/init%.d/stubby enable"))
        assert.truthy(H.exec_cmds()[2]:find("^ls "))
    end)

    it("disable reports disabled state", function()
        H.begin({})
        local r = H.reload("podkop-tweaker.api_stubby").autostart_toggle("disable")
        assert.same({ success = true, enabled = false }, r)
    end)
end)
