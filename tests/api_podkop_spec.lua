-- api_podkop_spec | v1.2.0 | 19.10.2026 | Explicit checked pipe responders and actual transport counts

package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path

local H = require("pt_harness")

local CFG = "/etc/config/podkop"
local BAK = "/etc/config/podkop.auto-backup"
local RC = "/etc/rc.d/S99podkop"
local ORIG = "/etc/init.d/podkop.orig"
local URL = "https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh"

local VALID = "config podkop 'main'\n\toption enabled '1'\n"
local OLD = "config podkop 'main'\n\toption enabled '0'\n"
local SERVICE_COMMANDS = {
    restart = "/etc/init.d/podkop restart 2>&1",
    start = "'/etc/init.d/podkop' start", stop = "'/etc/init.d/podkop' stop",
    enable = "/etc/init.d/podkop enable", disable = "/etc/init.d/podkop disable"
}

local function service_reply(action, output)
    local expected = assert(SERVICE_COMMANDS[action])
    return { match = function(cmd)
        return cmd == require("podkop-tweaker.services").checked_command(expected)
    end, out = output }
end

local INFO_JSON = '{"podkop_version":"1.9.2","podkop_latest_version":"2.0.0",' ..
    '"luci_app_version":"4.1.0","sing_box_version":"1.10.0",' ..
    '"openwrt_version":"25.12.5","device_model":"GL-MT6000"}'

local function pid_reply(output)
    return { match = function(cmd)
        return cmd:find("pidof", 1, true) and cmd:find("sing-box", 1, true)
    end, out = output }
end

local function begin_podkop(opts)
    opts = opts or {}
    opts.sys = opts.sys or {}
    local network = opts.popen
    local pipes = type(network) == "table" and network or {}
    for _, reply in ipairs(opts.sys) do pipes[#pipes + 1] = reply end
    for _, action in ipairs({ "restart", "start", "stop", "enable", "disable" }) do
        table.insert(pipes, service_reply(action, "\nPT_EXIT:0\n"))
    end
    table.insert(pipes, pid_reply("\nPT_EXIT:1\n"))
    if type(network) == "function" then
        pipes[#pipes + 1] = { match = function(command) return not command:find("PT_EXIT:", 1, true) end, out = network }
    end
    opts.popen = pipes
    H.begin(opts)
    local UPD = H.reload("podkop-tweaker.api_update")
    UPD.init("4.1.0")
    local PDK = H.reload("podkop-tweaker.api_podkop")
    return PDK
end

local function commands_containing(text)
    local result = {}
    for _, commands in ipairs({ H.exec_cmds(), H.popen_cmds() }) do
        for _, cmd in ipairs(commands) do
            if cmd:find(text, 1, true) then result[#result + 1] = cmd end
        end
    end
    return result
end

local function assert_restart(resp, running, instance)
    assert.is_true(resp.success)
    assert.is_true(resp.restarting)
    assert.is_true(resp.command_result_known)
    assert.equal(0, resp.command_exit_code)
    assert.is_true(resp.verification_required)
    assert.equal(running or false, resp.previous_running)
    assert.is_true(resp.previous_identity_known)
    assert.equal(instance, resp.previous_instance)
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

    -- Real release parsing/cache and live APK inventory, with memory-only curl.
    local function argon_fixture(opts)
        opts = opts or {}
        local state = { current = opts.current or "2.4.8-r2", target = opts.target or "3.0.0-r2",
            locale = opts.locale, checks = 0 }
        local PDK = begin_podkop({
            sys = {
                { match = "podkop get_system_info", out = opts.podkop or INFO_JSON },
                { match = "stubby -V", out = "Stubby 0.4.3\n" },
                { match = "apk list --installed --manifest", out = function()
                    return "base-files 1666~native-r1\nluci-theme-argon " .. state.current .. "\n" ..
                        (state.locale and "luci-i18n-argon-config-ru " .. state.locale .. "\n" or "")
                end },
                { match = "apk --version", out = "apk-tools 3.0.3\n" },
                { match = "pidof uhttpd", out = "100\n" },
                { match = "api.github.com/repos/InsaniaQuon",
                    out = '{"tag_name":"v4.9.9","assets":[{"browser_download_url":"https://github.com/InsaniaQuon/luci-app-podkop-tweaker/releases/download/v4.9.9/x.tar.gz"}]}' }
            },
            popen = function(cmd)
                assert.truthy(cmd:find("api.github.com/repos/jerrykuku", 1, true))
                state.checks = state.checks + 1
                local release = { tag_name = "v" .. state.target:match("^(%d+%.%d+%.%d+)"), assets = {} }
                for _, name in ipairs({ "luci-theme-argon", "luci-app-argon-config", "luci-i18n-argon-config-ru" }) do
                    local file = name .. "-" .. state.target .. ".apk"
                    release.assets[#release.assets + 1] = { name = file, size = 10, digest = "sha256:" .. string.rep("a", 64),
                        browser_download_url = "https://github.com/jerrykuku/luci-theme-argon/releases/download/" .. release.tag_name .. "/" .. file }
                end
                return H.json.stringify(state.bad_metadata and { tag_name = release.tag_name, assets = {} } or release) .. "\nPT_CURL_EXIT:0\n"
            end
        })
        H.vfs_write("/etc/openwrt_release", "DISTRIB_RELEASE='25.12.5'\n")
        return PDK, state
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

    it("surfaces full installed/target APK versions and the backend decision", function()
        local PDK = argon_fixture()
        local r = PDK.system_info()
        assert.equal("2.4.8-r2", r.argon_theme_version)
        assert.equal("3.0.0-r2", r.argon_theme_latest)
        assert.is_true(r.argon_theme_update_available)
        assert.is_false(r.argon_theme_resume_available)
        assert.is_nil(r.argon_theme_error)
    end)

    it("keeps an exact r1 to r2 update actionable", function()
        local PDK = argon_fixture({ current = "3.0.0-r1" })
        local r = PDK.system_info()
        assert.equal("3.0.0-r1", r.argon_theme_version)
        assert.equal("3.0.0-r2", r.argon_theme_latest)
        assert.is_true(r.argon_theme_update_available)
    end)

    it("recomputes equal-theme locale updates from live inventory, not cached decisions", function()
        local PDK, state = argon_fixture({ current = "3.0.0-r2", locale = "3.0.0-r1" })
        assert.is_true(PDK.system_info().argon_theme_update_available)
        state.locale = "3.0.0-r2"
        local r = PDK.system_info()
        assert.equal(r.argon_theme_version, r.argon_theme_latest)
        assert.is_false(r.argon_theme_update_available)
        assert.equal(1, state.checks, "release cache is reused, installed inventory is not")
    end)

    it("forwards same-version recovery phase even when Podkop info is unavailable", function()
        local PDK = argon_fixture({ current = "3.0.0-r2", podkop = "" })
        require("podkop-tweaker.theme").check = function(force)
            assert.is_false(force)
            return { current_version = "3.0.0-r2", latest_version = "3.0.0-r2",
                update_available = true, resume_available = true, phase = "css" }
        end
        local r = PDK.system_info()
        assert.equal("Failed to get system info from podkop", r.error)
        assert.equal("3.0.0-r2", r.argon_theme_version)
        assert.equal("3.0.0-r2", r.argon_theme_latest)
        assert.is_true(r.argon_theme_update_available)
        assert.is_true(r.argon_theme_resume_available)
        assert.equal("css", r.argon_theme_phase)
    end)

    it("preserves unsupported/metadata errors instead of treating them as up to date", function()
        local PDK, state = argon_fixture()
        H.vfs_write("/etc/openwrt_release", "DISTRIB_RELEASE='24.10.0'\n")
        local r = PDK.system_info()
        assert.is_false(r.argon_theme_update_available)
        assert.equal("2.4.8-r2", r.argon_theme_version)
        assert.truthy(r.argon_theme_error)
        H.vfs_write("/etc/openwrt_release", "DISTRIB_RELEASE='25.12.5'\n")
        state.bad_metadata = true
        local forced = PDK.check_updates().theme
        assert.is_false(forced.update_available)
        assert.truthy(forced.error)
        assert.equal("2.4.8-r2", forced.current_version)
    end)

    it("no installed theme -> nil version, no network theme check", function()
        local sr = sys_ok()
        local PDK = begin_podkop({ sys = { sr[1], sr[2] } })
        local r = PDK.system_info()
        assert.is_nil(r.argon_theme_version)
        assert.is_nil(r.argon_theme_latest)
        assert.is_false(r.argon_theme_update_available)
        assert.is_false(r.argon_theme_resume_available)
        -- Even an obsolete check stub cannot invent an installed theme.
        require("podkop-tweaker.theme").check = function() error("theme check must not run without Argon") end
        assert.is_false(PDK.check_updates().theme.update_available)
        assert.equal(0, #H.popen_cmds(), "no release request, including force check")
    end)

    it("podkop update snapshot cached for 24h overrides live latest", function()
        local PDK = begin_podkop({ sys = sys_ok() })
        H.vfs_write("/tmp/pt_podkop_check.json",
            '{"latest_version":"9.9.9","update_available":true,"cached_at":' .. os.time() .. '}')
        local r = PDK.system_info()
        assert.equal("9.9.9", r.podkop_latest_version)
        assert.is_true(r.update_available)
    end)

    it("check_updates: forces all three sources", function()
        local PDK, state = argon_fixture()
        assert.equal("3.0.0-r2", PDK.system_info().argon_theme_latest)
        state.target = "3.0.0-r3"
        local r = PDK.check_updates()
        assert.equal("2.0.0", r.podkop.latest_version)
        assert.is_true(r.podkop.update_available)
        assert.equal("4.9.9", r.tweaker.latest_version)
        assert.is_true(r.tweaker.update_available)
        assert.equal("2.4.8-r2", r.theme.current_version)
        assert.equal("3.0.0-r3", r.theme.latest_version)
        assert.is_true(r.theme.update_available)
        assert.is_false(r.theme.resume_available)
        assert.equal(2, state.checks, "force bypasses the fresh release cache")
        -- tweaker cache was force-refreshed (old cache file gone, new written)
        assert.truthy(H.vfs_read("/tmp/tweaker_check_cache.json"):find("4.9.9", 1, true))
    end)

    it("check_updates: podkop info failure -> per-source error", function()
        local PDK = argon_fixture({ podkop = "" })
        local r = PDK.check_updates()
        assert.equal("Failed to get podkop info", r.podkop.error)
        assert.equal("3.0.0-r2", r.theme.latest_version)
        assert.is_true(r.theme.update_available)
    end)

    it("force check retains the complete pinned recovery decision and diagnostics", function()
        local PDK = argon_fixture({ current = "3.0.0-r2" })
        local details = string.rep("complete diagnostic line\n", 100)
        require("podkop-tweaker.theme").check = function(force)
            assert.is_true(force)
            return { current_version = "3.0.0-r2", latest_version = "3.0.0-r2",
                update_available = false, resume_available = true, phase = "translation",
                error = "Missing release APK for installed package", details = details }
        end
        local r = PDK.check_updates().theme
        assert.equal("3.0.0-r2", r.current_version)
        assert.equal("3.0.0-r2", r.latest_version)
        assert.is_false(r.update_available)
        assert.is_true(r.resume_available)
        assert.equal("translation", r.phase)
        assert.equal("Missing release APK for installed package", r.error)
        assert.equal(details, r.details)
    end)

    it("readiness matches the full target revision, not just the theme semver", function()
        local PDK, state = argon_fixture({ current = "3.0.0-r1" })
        assert.equal("3.0.0-r2", PDK.system_info().argon_theme_latest)
        local id = string.rep("b", 32)
        H.vfs_write("/tmp/pt-web-restart.json", H.json.stringify({ id = id, target = "theme", state = "applied",
            started = os.time(), previous_instance = "100:1000", expected_version = "3.0.0-r2" }))
        H.vfs_write("/proc/100/stat", "100 (uhttpd) S " .. string.rep("0 ", 18) .. "2000\n")
        local UPD = require("podkop-tweaker.api_update")
        local r = UPD.restart_status(id)
        assert.is_true(r.restarted)
        assert.equal("3.0.0-r1", r.installed_version)
        assert.equal("3.0.0-r2", r.expected_version)
        assert.is_false(r.ready)
        state.current = "3.0.0-r2"
        assert.is_true(UPD.restart_status(id).ready)
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
        assert.equal(1, #commands_containing("pkill -f 'ttyd.*7682'"))
        local cmd = commands_containing("ttyd -p 7682")[1]
        assert.truthy(cmd:find("^ttyd %-p 7682 sh %-c 'wget %-O /tmp/podkop%-install%.sh " .. URL:gsub("%.", "%%.") .. " && sh /tmp/podkop%-install%.sh' >/dev/null 2>&1 &$"))
        assert.falsy(cmd:find("podkop-fragment enable", 1, true))
    end)

    it("wrapper active: reinstall tail appended", function()
        local PDK = begin_podkop({})
        H.vfs_write(CFG, OLD)
        H.vfs_write(ORIG, "wrapper")
        PDK.update_start()
        local cmd = commands_containing("ttyd -p 7682")[1]
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
        assert_restart(r)
        assert.equal(OLD, H.vfs_read(BAK))
        assert.equal(VALID, H.vfs_read(CFG))
        assert.equal(1, #commands_containing("/etc/init.d/podkop restart"))
    end)

    it("save: missing config is an explicit first install", function()
        local PDK = begin_podkop({})
        assert_restart(PDK.save_config(VALID))
        assert.equal(VALID, H.vfs_read(CFG))
        assert.is_nil(H.vfs_read(BAK))
    end)

    it("save: failed owned-stage write preserves live config and usable backup", function()
        local PDK = begin_podkop({})
        H.vfs_write(CFG, OLD)
        H.vfs_write(BAK, VALID)
        H.state().failures[CFG .. ".*"] = { write = true, partial = 7 }
        local r = PDK.save_config(VALID)
        assert.truthy(r.error)
        assert.falsy(r.success)
        assert.falsy(r.applied)
        assert.equal(OLD, H.vfs_read(CFG))
        assert.equal(VALID, H.vfs_read(BAK))
        assert.equal(0, #commands_containing("/etc/init.d/podkop restart"))
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

    it("Save alone skips identical content; explicit Import still requests a restart", function()
        local PDK = begin_podkop({})
        H.vfs_write(CFG, VALID)
        assert.is_true(PDK.save_config(VALID).unchanged)
        assert.equal(0, #commands_containing("/etc/init.d/podkop restart"))
        assert_restart(PDK.import_config(VALID))
        assert.equal(1, #commands_containing("/etc/init.d/podkop restart"))
    end)

    it("forwards the full shared response and Save options without reducing metadata", function()
        local PDK = begin_podkop({})
        local SRV = require("podkop-tweaker.services")
        local result = { success = false, applied = true, verification_required = true,
            previous_running = true, previous_identity_known = true, previous_instance = "42:101",
            error = "restart failed", details = string.rep("full diagnostic\n", 100), warning = "backup retained" }
        local calls = {}
        SRV.apply_service = function(svc, content, options)
            assert.equal(SRV.podkop, svc)
            assert.equal(VALID, content)
            calls[#calls + 1] = options or {}
            return result
        end
        assert.equal(result, PDK.save_config(VALID))
        assert.is_true(calls[1].skip_unchanged)
        assert.equal(result, PDK.import_config(VALID))
        assert.falsy(calls[2].skip_unchanged)
    end)

    it("quiet nonzero restart is an applied-disk failure, not a successful save", function()
        local PDK = begin_podkop({ sys = {
            service_reply("restart", "\nPT_EXIT:19\n"),
            pid_reply("42\nPT_EXIT:0\n")
        } })
        H.vfs_write("/proc/42/stat", "42 (sing-box) S " .. string.rep("0 ", 18) .. "101\n")
        H.vfs_write(CFG, OLD)
        local r = PDK.save_config(VALID)
        assert.is_false(r.success)
        assert.is_true(r.applied)
        assert.is_true(r.command_result_known)
        assert.equal(19, r.command_exit_code)
        assert.is_true(r.verification_required)
        assert.is_true(r.previous_running)
        assert.is_true(r.previous_identity_known)
        assert.equal("42:101", r.previous_instance)
        assert.truthy(r.error)
        assert.equal(VALID, H.vfs_read(CFG))
        assert.equal(OLD, H.vfs_read(BAK))
        assert.equal(1, #commands_containing("/etc/init.d/podkop restart"), "mutation is never replayed")
    end)
end)

describe("api_podkop.service_status/toggle", function()
    it("status via pidof sing-box", function()
        local PDK = begin_podkop({ strict = true, sys = { pid_reply("42\nPT_EXIT:0\n") } })
        H.vfs_write("/proc/42/stat", "42 (sing-box) S " .. string.rep("0 ", 18) .. "101\n")
        local r = PDK.service_status()
        assert.is_true(r.running)
        assert.equal("42", r.pid)
        assert.equal("42:101", r.instance)
        H.finish()
        local PDK2 = begin_podkop({ strict = true })
        assert.is_false(PDK2.service_status().running)
    end)

    it("toggle: invalid rejected; start/stop exec + pid echo", function()
        local PDK = begin_podkop({ strict = true, sys = { pid_reply("7\nPT_EXIT:0\n") } })
        H.vfs_write("/proc/7/stat", "7 (sing-box) S " .. string.rep("0 ", 18) .. "102\n")
        assert.same({ success = false, error = "Invalid action" }, PDK.service_toggle("reload"))
        local started = PDK.service_toggle("start")
        assert.is_true(started.success)
        assert.is_true(started.running)
        assert.equal(1, #commands_containing(SERVICE_COMMANDS.start))
        H.finish()

        local PDK2 = begin_podkop({ strict = true })
        local stopped = PDK2.service_toggle("stop")
        assert.is_true(stopped.success)
        assert.is_false(stopped.running)
        assert.equal(1, #commands_containing(SERVICE_COMMANDS.stop))
    end)

    it("preserves Unknown status and failed service-command diagnostics", function()
        local details = string.rep("pid query failed\n", 40)
        local PDK = begin_podkop({ strict = true, sys = {
            pid_reply(details .. "\nPT_EXIT:2\n"),
            service_reply("start", "\nPT_EXIT:1\n")
        } })
        local status = PDK.service_status()
        assert.truthy(status.error)
        assert.is_nil(status.running)
        local result = PDK.service_toggle("start")
        assert.is_false(result.success)
        assert.truthy(result.error)
    end)
end)

describe("api_podkop.rollback", function()
    it("missing backup -> friendly error", function()
        local PDK = begin_podkop({})
        assert.equal("Backup file not found", PDK.rollback().error)
    end)

    it("restores and restarts", function()
        local PDK = begin_podkop({})
        H.vfs_write(BAK, OLD)
        H.vfs_write(CFG, "broken")
        assert_restart(PDK.rollback())
        assert.equal(OLD, H.vfs_read(CFG))
        assert.equal(1, #commands_containing("/etc/init.d/podkop restart"))
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
        assert.equal(1, #commands_containing("/etc/init.d/podkop enable"))
        H.finish()

        local PDK2 = begin_podkop({})
        assert.same({ success = true, enabled = false }, PDK2.autostart_toggle("disable"))
        assert.equal(1, #commands_containing("/etc/init.d/podkop disable"))
    end)

    it("failed autostart commands never return success or inferred disabled state", function()
        local details = string.rep("enable failed\n", 100)
        local PDK = begin_podkop({ sys = { service_reply("enable", details .. "\nPT_EXIT:4\n") } })
        local r = PDK.autostart_toggle("enable")
        assert.is_false(r.success)
        assert.equal(details, r.details)
        assert.is_nil(r.enabled)
    end)

    it("autostart open/close failures are read errors, not disabled", function()
        local PDK = begin_podkop({ failures = { [RC] = { open = true, errno = 13 } } })
        assert.truthy(PDK.autostart().error)
        assert.is_nil(PDK.autostart().enabled)
        H.state().failures[RC] = { close = true }
        H.vfs_write(RC, "link")
        assert.truthy(PDK.autostart_toggle("enable").error)
    end)

    it("successful command with unchanged autostart state is not confirmed", function()
        local PDK = begin_podkop({})
        local r = PDK.autostart_toggle("enable")
        assert.is_false(r.success)
        assert.is_false(r.enabled)
        assert.truthy(r.error)
    end)
end)
