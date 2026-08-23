-- api_podkop_spec | v1.0.0 | 23.08.2026 | Max-coverage specs for V2 pure handlers of api_podkop

package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path

local H = require("pt_harness")

local CFG = "/etc/config/podkop"
local BAK = "/etc/config/podkop.auto-backup"
local RC = "/etc/rc.d/S99podkop"
local ORIG = "/etc/init.d/podkop.orig"
local URL = "https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh"

local VALID = "config podkop 'main'\n\toption enabled '1'\n"
local OLD = "config podkop 'main'\n\toption enabled '0'\n"

local INFO_JSON = '{"podkop_version":"1.9.2","podkop_latest_version":"2.0.0",' ..
    '"luci_app_version":"4.1.0","sing_box_version":"1.10.0",' ..
    '"openwrt_version":"25.12.5","device_model":"GL-MT6000"}'

local function begin_podkop(opts)
    H.begin(opts)
    local UPD = H.reload("podkop-tweaker.api_update")
    UPD.init("4.1.0")
    local PDK = H.reload("podkop-tweaker.api_podkop")
    return PDK
end

after_each(function()
    H.finish()
end)

describe("api_podkop.system_info", function()
    local function sys_ok(stubby_line)
        return {
            { match = "podkop get_system_info", out = INFO_JSON },
            { match = "stubby -V", out = stubby_line or "Stubby 0.4.3\n" }
        }
    end

    it("full info: parsers, version compare, stubby line", function()
        local PDK = begin_podkop({ sys = sys_ok() })
        local r = PDK.system_info()
        assert.equal("1.9.2", r.podkop_version)
        assert.equal("2.0.0", r.podkop_latest_version)
        assert.equal("4.1.0", r.luci_app_version)
        assert.equal("0.4.3", r.stubby_version)
        assert.equal("1.10.0", r.sing_box_version)
        assert.equal("GL-MT6000", r.device_model)
        assert.is_true(r.update_available)
        assert.equal("4.1.0", r.tweaker_version)
        assert.is_nil(r.tweaker_latest)
        assert.falsy(r.error)
    end)

    it("no update when versions equal or latest unknown", function()
        local PDK = begin_podkop({
            sys = {
                { match = "podkop get_system_info", out = '{"podkop_version":"2.0.0","podkop_latest_version":"2.0.0"}' },
                { match = "stubby -V", out = "" }
            }
        })
        assert.is_false(PDK.system_info().update_available)

        H.finish()
        local PDK2 = begin_podkop({
            sys = {
                { match = "podkop get_system_info", out = '{"podkop_version":"1.0.0","podkop_latest_version":"unknown"}' }
            }
        })
        local r2 = PDK2.system_info()
        assert.is_false(r2.update_available)
        assert.equal("not installed", r2.stubby_version)
    end)

    it("tweaker_latest surfaced from cache file when fresh", function()
        H.begin({ sys = sys_ok("") })
        H.vfs_write("/tmp/tweaker_check_cache.json",
            '{"latest_version":"9.9.9","cached_at":' .. os.time() .. '}')
        local UPD = H.reload("podkop-tweaker.api_update")
        UPD.init("4.1.0")
        local PDK = H.reload("podkop-tweaker.api_podkop")
        assert.equal("9.9.9", PDK.system_info().tweaker_latest)
    end)

    it("legacy luci.json parser wins when it returns a table", function()
        local PDK = begin_podkop({
            sys = sys_ok(""),
            legacy_json = { podkop_version = "LEGACY", podkop_latest_version = "unknown" }
        })
        assert.equal("LEGACY", PDK.system_info().podkop_version)
    end)

    it("cjson rescues when jsonc parse fails", function()
        local PDK = begin_podkop({
            sys = { { match = "podkop get_system_info", out = "not-json" } },
            cjson = function() return { podkop_version = "CJK", podkop_latest_version = "unknown" } end
        })
        assert.equal("CJK", PDK.system_info().podkop_version)
    end)

    it("all parsers dead -> unknown table with error", function()
        local PDK = begin_podkop({ sys = { { match = "podkop get_system_info", out = "" } } })
        local r = PDK.system_info()
        assert.equal("unknown", r.podkop_version)
        assert.is_false(r.update_available)
        assert.equal("Failed to get system info from podkop", r.error)
        assert.equal("4.1.0", r.tweaker_version)
    end)

    it("parsed table without podkop_version -> unknown branch", function()
        local PDK = begin_podkop({
            sys = { { match = "podkop get_system_info", out = '{"foo":1}' } }
        })
        assert.equal("unknown", PDK.system_info().podkop_version)
    end)
end)

describe("api_podkop.update_start", function()
    it("backup failure -> exact error, no pkill", function()
        local PDK = begin_podkop({})
        local S = require("pt-subs-lib")
        S.backup_config = function() return false end
        assert.same({ error = "Cannot create backup before update" }, PDK.update_start())
        assert.equal(0, #H.exec_cmds())
    end)

    it("happy without wrapper: pkill, ttyd cmd with install URL, default host", function()
        local PDK = begin_podkop({})
        H.vfs_write(CFG, OLD)
        local r = PDK.update_start()
        assert.same({ success = true, url = "http://127.0.0.1:7682" }, r)
        local cmds = H.exec_cmds()
        assert.equal(2, #cmds)
        assert.equal("pkill -f 'ttyd.*7682' 2>/dev/null", cmds[1])
        assert.truthy(cmds[2]:find("^ttyd %-p 7682 sh %-c 'wget %-O /tmp/podkop%-install%.sh " .. URL:gsub("%.", "%%.") .. " && sh /tmp/podkop%-install%.sh' >/dev/null 2>&1 &$"))
        assert.falsy(cmds[2]:find("podkop%-fragment enable", 1, true))
    end)

    it("wrapper active: reinstall tail appended", function()
        local PDK = begin_podkop({})
        H.vfs_write(CFG, OLD)
        H.vfs_write(ORIG, "wrapper")
        PDK.update_start()
        local cmd = H.exec_cmds()[2]
        assert.truthy(cmd:find("rm -f /etc/init.d/podkop.orig && /etc/init.d/podkop-fragment enable", 1, true))
    end)

    it("host taken from SERVER_NAME", function()
        local PDK = begin_podkop({ env = { SERVER_NAME = "192.168.8.1" } })
        H.vfs_write(CFG, OLD)
        assert.equal("http://192.168.8.1:7682", PDK.update_start().url)
    end)
end)

describe("api_podkop.save_config/import_config", function()
    it("save: empty and invalid content rejected", function()
        local PDK = begin_podkop({})
        assert.same({ error = "Configuration is empty" }, PDK.save_config(""))
        assert.same({ error = "Invalid UCI format: no 'config' declarations found" },
            PDK.save_config("junk"))
        assert.equal(0, #H.exec_cmds())
    end)

    it("save happy: backup, write, restart", function()
        local PDK = begin_podkop({})
        H.vfs_write(CFG, OLD)
        local r = PDK.save_config(VALID)
        assert.same({ success = true, restarting = true }, r)
        assert.equal(OLD, H.vfs_read(BAK))
        assert.equal(VALID, H.vfs_read(CFG))
        assert.equal("/etc/init.d/podkop restart 2>&1", H.exec_cmds()[1])
    end)

    it("save: missing config file -> backup error", function()
        local PDK = begin_podkop({})
        assert.same({ error = "Cannot create backup" }, PDK.save_config(VALID))
    end)

    it("save: write failure passthrough", function()
        local PDK = begin_podkop({})
        H.vfs_write(CFG, OLD)
        local SRV = require("podkop-tweaker.services")
        SRV.write_file_atomic = function() return false, "werr" end
        assert.same({ error = "werr" }, PDK.save_config(VALID))
    end)

    it("import via content field", function()
        local PDK = begin_podkop({})
        H.vfs_write(CFG, OLD)
        assert.is_true(PDK.import_config(VALID, nil).restarting)
        assert.equal(VALID, H.vfs_read(CFG))
    end)

    it("import falls back to file table then string", function()
        local PDK = begin_podkop({})
        H.vfs_write(CFG, OLD)
        assert.is_true(PDK.import_config("", { data = VALID, name = "x" }).restarting)
        H.finish()

        local PDK2 = begin_podkop({})
        H.vfs_write(CFG, OLD)
        assert.is_true(PDK2.import_config("", VALID).restarting)
        assert.equal(VALID, H.vfs_read(CFG))
    end)

    it("import with nothing -> empty validation error", function()
        local PDK = begin_podkop({})
        assert.same({ error = "Configuration is empty" }, PDK.import_config("", nil))
        assert.same({ error = "Configuration is empty" }, PDK.import_config("", {}))
    end)

    it("import invalid content -> validator error", function()
        local PDK = begin_podkop({})
        assert.same({ error = "Invalid UCI format: no 'config' declarations found" },
            PDK.import_config("nope", nil))
    end)
end)

describe("api_podkop.service_status/toggle", function()
    it("status via pidof sing-box", function()
        local PDK = begin_podkop({ sys = { { match = "pidof sing-box", out = "42\n" } } })
        assert.same({ running = true, pid = "42" }, PDK.service_status())
        H.finish()
        local PDK2 = begin_podkop({})
        assert.same({ running = false, pid = nil }, PDK2.service_status())
    end)

    it("toggle: invalid rejected; start/stop exec + pid echo", function()
        local PDK = begin_podkop({ sys = { { match = "pidof sing-box", out = "7\n" } } })
        assert.same({ error = "Invalid action" }, PDK.service_toggle("reload"))
        assert.same({ success = true, running = true }, PDK.service_toggle("start"))
        assert.truthy(H.exec_cmds()[1]:find("^/etc/init%.d/podkop start"))
        H.finish()

        local PDK2 = begin_podkop({})
        assert.same({ success = true, running = false }, PDK2.service_toggle("stop"))
        assert.truthy(H.exec_cmds()[1]:find("^/etc/init%.d/podkop stop"))
    end)
end)

describe("api_podkop.rollback", function()
    it("missing backup -> friendly error", function()
        local PDK = begin_podkop({})
        assert.same({ error = "Backup file not found" }, PDK.rollback())
    end)

    it("restores and restarts", function()
        local PDK = begin_podkop({})
        H.vfs_write(BAK, OLD)
        H.vfs_write(CFG, "broken")
        assert.same({ success = true, restarting = true }, PDK.rollback())
        assert.equal(OLD, H.vfs_read(CFG))
        assert.equal("/etc/init.d/podkop restart 2>&1", H.exec_cmds()[1])
    end)
end)

describe("api_podkop.autostart", function()
    it("enabled when rc symlink exists", function()
        local PDK = begin_podkop({})
        H.vfs_write(RC, "link")
        assert.is_true(PDK.autostart().enabled)
    end)

    it("disabled when absent", function()
        local PDK = begin_podkop({})
        assert.is_false(PDK.autostart().enabled)
    end)

    it("toggle invalid action", function()
        local PDK = begin_podkop({})
        assert.same({ error = "Invalid action" }, PDK.autostart_toggle("on"))
        assert.equal(0, #H.exec_cmds())
    end)

    it("toggle enable/disable reflect rc presence after exec", function()
        local PDK = begin_podkop({})
        H.vfs_write(RC, "link")
        assert.same({ success = true, enabled = true }, PDK.autostart_toggle("enable"))
        assert.truthy(H.exec_cmds()[1]:find("^/etc/init%.d/podkop enable"))
        H.finish()

        local PDK2 = begin_podkop({})
        assert.same({ success = true, enabled = false }, PDK2.autostart_toggle("disable"))
        assert.truthy(H.exec_cmds()[1]:find("^/etc/init%.d/podkop disable"))
    end)
end)
