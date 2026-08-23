-- api_singbox_spec | v1.0.0 | 23.08.2026 | Max-coverage specs for V2 pure handlers of api_singbox

package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path

local H = require("pt_harness")

local CFG = "/etc/sing-box/config.json"
local BAK = "/etc/sing-box/config.json.auto-backup"
local ORIG = "/etc/init.d/podkop.orig"
local INIT_PODKOP = "/etc/init.d/podkop"

local SB_OK = '{"outbounds":[{"type":"direct"},{"type":"mixed","listen":"127.0.0.1","listen_port":2080}],"route":{"final":"proxy"}}'
local SB_ORIG = '{"orig":1}'

local function begin_sbx(opts)
    opts = opts or {}
    opts.sys = opts.sys or {}
    if opts.check == nil then opts.check = "" end
    table.insert(opts.sys, { match = "sing-box check", out = opts.check })
    H.begin(opts)
    if opts.seed_cfg == nil then H.vfs_write(CFG, SB_OK) end
    return H.reload("podkop-tweaker.api_singbox")
end

local function jq_out(text)
    return { match = "jq ", out = text }
end

after_each(function()
    H.finish()
end)

describe("api_singbox.save_config", function()
    it("empty and oversize rejected via content check", function()
        local SBX = begin_sbx({})
        assert.same({ error = "Configuration is empty" }, SBX.save_config(""))
        assert.same({ error = "Config too large (max 2MB)" }, SBX.save_config(string.rep("x", 2097153)))
    end)

    it("identical content -> unchanged, no side effects", function()
        local SBX = begin_sbx({})
        assert.same({ success = true, unchanged = true }, SBX.save_config(SB_OK))
        assert.falsy(H.vfs_exists(BAK))
        assert.equal(0, #H.exec_cmds())
    end)

    it("happy first write: check, rename, restart", function()
        local SBX = begin_sbx({})
        local r = SBX.save_config('{"new":true}')
        assert.same({ success = true, restarting = true }, r)
        assert.equal('{"new":true}', H.vfs_read(CFG))
        assert.falsy(H.vfs_exists(CFG .. ".tmp-write"))
        assert.equal(2, #H.exec_cmds())
        assert.truthy(H.exec_cmds()[1]:find("^sing%-box check %-c "))
        assert.equal("/etc/init.d/sing-box restart 2>&1", H.exec_cmds()[2])
    end)

    it("update keeps backup of previous content", function()
        local SBX = begin_sbx({})
        assert.is_true(SBX.save_config('{"v":2}').restarting)
        assert.equal(SB_OK, H.vfs_read(BAK))
    end)

    it("check failure: tmp removed, disk intact, details returned", function()
        local SBX = begin_sbx({ check = "decode error: bad json\n" })
        local r = SBX.save_config('{"bad":}')
        assert.same({ error = "sing-box check failed", details = "decode error: bad json\n" }, r)
        assert.equal(SB_OK, H.vfs_read(CFG))
        assert.falsy(H.vfs_exists(CFG .. ".tmp-write"))
    end)
end)

describe("api_singbox.import_config", function()
    it("empty content rejected", function()
        local SBX = begin_sbx({})
        assert.same({ error = "Empty content" }, SBX.import_config(""))
    end)

    it("check failure leaves config untouched", function()
        local SBX = begin_sbx({ check = "boom\n" })
        local r = SBX.import_config('{"x":1}')
        assert.same({ error = "sing-box check failed", details = "boom\n" }, r)
        assert.equal(SB_OK, H.vfs_read(CFG))
        assert.falsy(H.vfs_exists(CFG .. ".tmp-import"))
    end)

    it("happy: backup then replace then restart", function()
        local SBX = begin_sbx({})
        local r = SBX.import_config('{"imported":42}')
        assert.same({ success = true, restarting = true }, r)
        assert.equal(SB_OK, H.vfs_read(BAK))
        assert.equal('{"imported":42}', H.vfs_read(CFG))
        assert.falsy(H.vfs_exists(CFG .. ".tmp-import"))
    end)
end)

describe("api_singbox.service_status/toggle", function()
    it("status via pidof", function()
        local SBX = begin_sbx({ sys = { { match = "pidof sing-box", out = "55\n" } } })
        assert.same({ running = true, pid = "55" }, SBX.service_status())
        H.finish()
        local SBX2 = begin_sbx({})
        assert.same({ running = false, pid = nil }, SBX2.service_status())
    end)

    it("toggle validates action and reports running state", function()
        local SBX = begin_sbx({ sys = { { match = "pidof sing-box", out = "8\n" } } })
        assert.same({ error = "Invalid action" }, SBX.service_toggle("reload"))
        assert.same({ success = true, running = true }, SBX.service_toggle("start"))
        assert.truthy(H.exec_cmds()[1]:find("^/etc/init%.d/sing%-box start"))
        H.finish()
        local SBX2 = begin_sbx({})
        assert.same({ success = true, running = false }, SBX2.service_toggle("stop"))
    end)
end)

describe("api_singbox.rollback", function()
    it("missing backup -> friendly error", function()
        local SBX = begin_sbx({})
        assert.same({ error = "Backup file not found" }, SBX.rollback())
    end)

    it("restores and restarts", function()
        local SBX = begin_sbx({})
        H.vfs_write(BAK, SB_ORIG)
        H.vfs_write(CFG, "broken")
        assert.same({ success = true, restarting = true }, SBX.rollback())
        assert.equal(SB_ORIG, H.vfs_read(CFG))
        assert.equal("/etc/init.d/sing-box restart 2>&1", H.exec_cmds()[1])
    end)
end)

describe("api_singbox.outbounds", function()
    it("empty jq output -> empty list", function()
        local SBX = begin_sbx({ sys = { jq_out("") } })
        assert.same({ outbounds = {} }, SBX.outbounds())
    end)

    it("parses jq lines into entries", function()
        local raw = '{"tag":"a","type":"vless","server":"s1","tls_enabled":true,"has_fragment":false}\n}\n' ..
            '{"tag":"b","type":"vmess","tls_enabled":false,"has_fragment":true}\n}\n'
        local SBX = begin_sbx({ sys = { jq_out(raw) } })
        assert.same({
            outbounds = {
                { tag = "a", type = "vless", server = "s1", tls_enabled = true, has_fragment = false },
                { tag = "b", type = "vmess", tls_enabled = false, has_fragment = true }
            }
        }, SBX.outbounds())
    end)

    it("garbage without closing braces yields nothing", function()
        local SBX = begin_sbx({ sys = { jq_out("junk line\n") } })
        assert.same({ outbounds = {} }, SBX.outbounds())
    end)
end)

describe("api_singbox.patch_fragment", function()
    it("invalid/empty tags rejected", function()
        local SBX = begin_sbx({})
        assert.same({ error = "No outbounds selected" }, SBX.patch_fragment("zz", nil, nil, nil, nil))
        assert.same({ error = "No outbounds selected" }, SBX.patch_fragment("[]", nil, nil, nil, nil))
    end)

    it("non-string or unsafe tag rejected", function()
        local SBX = begin_sbx({})
        assert.same({ error = "Invalid tag value" }, SBX.patch_fragment('[1]', nil, nil, nil, nil))
        assert.same({ error = "Invalid tag value" }, SBX.patch_fragment('["bad;tag"]', nil, nil, nil, nil))
    end)

    it("missing config -> cannot read", function()
        local SBX = begin_sbx({ seed_cfg = false })
        assert.same({ error = "Cannot read config" },
            SBX.patch_fragment('["proxy"]', "apply", "1", "1", nil))
    end)

    it("apply without methods -> exact error", function()
        local SBX = begin_sbx({})
        assert.same({ error = "Select at least one fragment method" },
            SBX.patch_fragment('["proxy"]', "apply", nil, nil, nil))
    end)

    it("bad fallback delay format rejected", function()
        local SBX = begin_sbx({})
        assert.same({ error = "Invalid fallback_delay format" },
            SBX.patch_fragment('["proxy"]', "apply", "1", nil, "abc"))
    end)

    it("remove mode: jq expr, backup, tmp->config, restart", function()
        local SBX = begin_sbx({ sys = { jq_out('{"patched":true}') } })
        local r = SBX.patch_fragment('["proxy","alt"]', "remove", nil, nil, nil)
        assert.same({ success = true, restarting = true }, r)
        assert.equal('{"patched":true}', H.vfs_read(CFG))
        assert.equal(SB_OK, H.vfs_read(BAK))
        assert.falsy(H.vfs_exists(CFG .. ".tmp-patch"))
        local jq_cmd = H.exec_cmds()[1]
        assert.truthy(jq_cmd:find("--arg t1 proxy", 1, true))
        assert.truthy(jq_cmd:find("--arg t2 alt", 1, true))
        assert.truthy(jq_cmd:find("del%(%.fragment, %.record_fragment, %.fragment_fallback_delay%)"))
        assert.truthy(jq_cmd:find("%$t1 or %.tag == %$t2"))
        assert.equal("/etc/init.d/sing-box restart 2>&1", H.exec_cmds()[3])
    end)

    it("apply both methods with custom delay", function()
        local SBX = begin_sbx({ sys = { jq_out("P") } })
        assert.is_true(SBX.patch_fragment('["proxy"]', "apply", "1", "1", "700ms").restarting)
        local jq_cmd = H.exec_cmds()[1]
        assert.truthy(jq_cmd:find('"fragment": true', 1, true))
        assert.truthy(jq_cmd:find('"record_fragment": %(true%)'))
        assert.truthy(jq_cmd:find('"fragment_fallback_delay": "700ms"', 1, true))
    end)

    it("record-only: fragment false + fallback removed", function()
        local SBX = begin_sbx({ sys = { jq_out("P") } })
        assert.is_true(SBX.patch_fragment('["proxy"]', "apply", nil, "1", nil).restarting)
        local jq_cmd = H.exec_cmds()[1]
        assert.truthy(jq_cmd:find('"fragment": false', 1, true))
        assert.truthy(jq_cmd:find('"record_fragment": true', 1, true))
        assert.truthy(jq_cmd:find("del%(%.fragment_fallback_delay%)"))
        -- record-only branch never adds a fallback value clause
        assert.falsy(jq_cmd:find('"fragment_fallback_delay": "', 1, true))
    end)

    it("jq empty output -> patch failed", function()
        local SBX = begin_sbx({ sys = { jq_out("") } })
        assert.same({ error = "jq patch failed" },
            SBX.patch_fragment('["proxy"]', "remove", nil, nil, nil))
    end)

    it("post-patch check failure: tmp removed, config intact", function()
        local SBX = begin_sbx({ sys = { jq_out("P") }, check = "bad after patch\n" })
        local r = SBX.patch_fragment('["proxy"]', "remove", nil, nil, nil)
        assert.same({ error = "sing-box check failed after patch", details = "bad after patch\n" }, r)
        assert.equal(SB_OK, H.vfs_read(CFG))
        assert.falsy(H.vfs_exists(CFG .. ".tmp-patch"))
    end)
end)

describe("api_singbox.wrapper_status", function()
    it("not installed", function()
        local SBX = begin_sbx({})
        assert.same({ installed = false, stale = false }, SBX.wrapper_status())
    end)

    it("stale when podkop init lacks patch marker", function()
        local SBX = begin_sbx({})
        H.vfs_write(ORIG, "orig")
        H.vfs_write(INIT_PODKOP, "#!/bin/sh\nstart_service(){}\n")
        assert.same({ installed = true, stale = true }, SBX.wrapper_status())
    end)

    it("active when marker present", function()
        local SBX = begin_sbx({})
        H.vfs_write(ORIG, "orig")
        H.vfs_write(INIT_PODKOP, "podkop-fragment-patch.sh\n")
        assert.same({ installed = true, stale = false }, SBX.wrapper_status())
    end)
end)

describe("api_singbox.wrapper_toggle", function()
    local function exit_responder(out)
        return { match = "podkop-fragment", out = out }
    end

    it("invalid action rejected", function()
        local SBX = begin_sbx({})
        assert.same({ error = "Invalid action" }, SBX.wrapper_toggle("toggle", nil, nil, nil))
        assert.equal(0, #H.exec_cmds())
    end)

    it("enable stores uci settings (bad delay coerced) and reports installed", function()
        local SBX = begin_sbx({ sys = { exit_responder("EXIT:0\n") } })
        H.vfs_write(ORIG, "created-by-script")
        local r = SBX.wrapper_toggle("enable", "1", nil, "abc", nil)
        assert.same({ success = true, installed = true }, r)
        assert.same({ "podkop-fragment" }, H.commits())
        local uci = require("luci.model.uci").cursor()
        assert.equal("true", uci:get("podkop-fragment", "settings", "fragment"))
        assert.equal("false", uci:get("podkop-fragment", "settings", "record_fragment"))
        assert.equal("500ms", uci:get("podkop-fragment", "settings", "fragment_fallback_delay"))
        assert.truthy(H.exec_cmds()[1]:find("^/etc/init%.d/podkop%-fragment enable 2>&1; echo EXIT:%$%?"))
    end)

    it("disable touches no uci", function()
        local SBX = begin_sbx({ sys = { exit_responder("EXIT:0\n") } })
        local r = SBX.wrapper_toggle("disable", nil, nil, nil)
        assert.same({ success = true, installed = false }, r)
        assert.equal(0, #H.commits())
    end)

    it("reinstall removes stale orig first, then enables", function()
        local SBX = begin_sbx({ sys = { exit_responder("EXIT:0\n") } })
        H.vfs_write(ORIG, "stale")
        local r = SBX.wrapper_toggle("reinstall", nil, nil, nil)
        assert.same({ success = true, installed = false }, r)
        local removed = false
        for _, c in ipairs(H.execute_cmds()) do
            if c:find("remove /etc/init.d/podkop.orig", 1, true) then removed = true end
        end
        assert.truthy(removed)
        assert.equal(0, #H.commits())
        assert.truthy(H.exec_cmds()[1]:find("podkop%-fragment enable"))
    end)

    it("non-zero exit -> trimmed error message", function()
        local SBX = begin_sbx({ sys = { exit_responder("wrapper failed badly\nEXIT:1\n") } })
        assert.same({ success = false, error = "wrapper failed badly" },
            SBX.wrapper_toggle("enable", nil, nil, nil))
    end)

    it("missing EXIT marker -> treated as failure", function()
        local SBX = begin_sbx({ sys = { exit_responder("weird output\n") } })
        local r = SBX.wrapper_toggle("disable", nil, nil, nil)
        assert.is_false(r.success)
        assert.equal("weird output", r.error)
    end)
end)

describe("api_singbox.fragment_settings", function()
    it("defaults when uci empty", function()
        local SBX = begin_sbx({})
        assert.same({ fragment = false, record_fragment = true, fallback_delay = "500ms" },
            SBX.fragment_settings())
    end)

    it("stored values mapped to booleans", function()
        begin_sbx({ uci = { ["podkop-fragment"] = { H.sec("settings", "settings", {
            fragment = "true", record_fragment = "false", fragment_fallback_delay = "300ms" }) } } })
        local SBX = H.reload("podkop-tweaker.api_singbox")
        assert.same({ fragment = true, record_fragment = false, fallback_delay = "300ms" },
            SBX.fragment_settings())
    end)
end)
