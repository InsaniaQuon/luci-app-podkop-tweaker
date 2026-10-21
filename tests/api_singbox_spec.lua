-- api_singbox_spec | v1.2.0 | 19.10.2026 | Direct checked pipes, detached-hook migration/status and UCI-preserving wrapper repair

package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path

local H = require("pt_harness")

local CFG = "/etc/sing-box/config.json"
local BAK = "/etc/sing-box/config.json.auto-backup"
local ORIG = "/etc/init.d/podkop.orig"
local INIT_PODKOP = "/etc/init.d/podkop"
local FRAGMENT_CONFIG = "/etc/config/podkop-fragment"
local FRAGMENT_RAW = "config fragment 'settings'\n\toption fragment 'true'\n\toption record_fragment 'false'\n\toption fragment_fallback_delay '300ms'\n"

local SB_OK = '{"outbounds":[{"type":"direct"},{"type":"mixed","listen":"127.0.0.1","listen_port":2080}],"route":{"final":"proxy"}}'
local SB_ORIG = '{"orig":1}'
local SB_PATCHED = '{"outbounds":[{"tag":"proxy","type":"vless","server":"s","tls":{"enabled":true,"record_fragment":true}}]}'
local LEGACY_HOOK = "( sleep 5 && /usr/bin/podkop-fragment-patch.sh ) &"
local OWNED_HOOK = "( sleep 5 && /usr/bin/podkop-fragment-patch.sh ) </dev/null >/dev/null 2>&1 &"
local SERVICE_COMMANDS = {
    restart = "/etc/init.d/sing-box restart 2>&1",
    start = "'/etc/init.d/sing-box' start", stop = "'/etc/init.d/sing-box' stop"
}

local function service_reply(action, output)
    local expected = assert(SERVICE_COMMANDS[action])
    return { match = function(cmd)
        return cmd == require("podkop-tweaker.services").checked_command(expected)
    end, out = output }
end

local function wrapper_init(start_hooks, reload_hooks, body)
    body = body or OWNED_HOOK
    local function lines(hooks)
        if type(hooks) ~= "table" then return string.rep("\t" .. body .. "\n", hooks) end
        local out = {}
        for _, hook in ipairs(hooks) do out[#out + 1] = "\t" .. hook .. "\n" end
        return table.concat(out)
    end
    return "#!/bin/sh /etc/rc.common\nUSE_PROCD=1\n\nstart_service() {\n" ..
        "\tprocd_open_instance\n\tprocd_close_instance\n" .. lines(start_hooks) ..
        "}\n\nreload_service() {\n\tstart_service\n" .. lines(reload_hooks) .. "}\n"
end

local function pid_reply(output)
    return { match = function(cmd)
        return cmd:find("pidof", 1, true) and cmd:find("sing-box", 1, true)
    end, out = output }
end

local function begin_sbx(opts)
    opts = opts or {}
    if opts.strict == nil then opts.strict = true end
    -- Checked foreground commands use direct io.popen; keep sys.exec responders
    -- separate so tests retain the real transport and cannot mask a regression.
    opts.popen = opts.popen or {}
    table.insert(opts.popen, { match = "sing-box check", out = opts.check or "\nPT_EXIT:0\n" })
    for _, action in ipairs({ "restart", "start", "stop" }) do
        table.insert(opts.popen, service_reply(action, "\nPT_EXIT:0\n"))
    end
    table.insert(opts.popen, pid_reply("\nPT_EXIT:1\n"))
    H.begin(opts)
    if opts.seed_cfg == nil then H.vfs_write(CFG, SB_OK) end
    return H.reload("podkop-tweaker.api_singbox")
end

local function jq_out(text, code)
    return { match = "jq ", out = text .. "\nPT_EXIT:" .. (code or 0) .. "\n" }
end

local function commands_containing(text)
    local result = {}
    for _, cmd in ipairs(H.popen_cmds()) do
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

local function assert_no_stages()
    for _, path in ipairs(H.stage_paths(CFG .. ".*")) do
        assert.is_nil(H.vfs_read(path), "owned stages must not remain after the operation")
    end
end

local function assert_outbounds_error(result)
    assert.truthy(result.error)
    assert.falsy(result.success)
    assert.is_nil(result.outbound_count)
    assert.is_nil(result.outbounds)
end

-- Explicit native RPC replies for this endpoint, independent of the harness's
-- per-option get() fake. The existing-file read must request the whole package.
local function fragment_rpc_reply(value, err)
    local uci = require("luci.model.uci").cursor()
    uci.get_all = function(self, config, section)
        assert.equal(uci, self)
        assert.equal("podkop-fragment", config)
        assert.is_nil(section)
        return value, err
    end
    return uci
end

after_each(function()
    H.finish()
end)

describe("api_singbox Save/Import integration", function()
    it("retains empty/oversize validation messages", function()
        local SBX = begin_sbx()
        assert.same({ error = "Configuration is empty" }, SBX.save_config(""))
        assert.same({ error = "Empty content" }, SBX.import_config(""))
        assert.same({ error = "Config too large (max 2MB)" }, SBX.save_config(string.rep("x", 2097153)))
    end)

    it("skips identical Save while explicit Import still requests a restart", function()
        local SBX = begin_sbx()
        assert.is_true(SBX.save_config(SB_OK).unchanged)
        assert.is_nil(H.vfs_read(BAK))
        assert.equal(0, #commands_containing("/etc/init.d/sing-box restart"))
        assert_restart(SBX.import_config(SB_OK))
        assert.equal(1, #commands_containing("/etc/init.d/sing-box restart"))
    end)

    it("publishes checked bytes, keeps a usable backup and forwards process-generation facts", function()
        local SBX = begin_sbx({ popen = { pid_reply("55\nPT_EXIT:0\n") } })
        H.vfs_write("/proc/55/stat", "55 (sing-box) S " .. string.rep("0 ", 18) .. "400\n")
        assert_restart(SBX.save_config('{"new":true}'), true, "55:400")
        assert.equal('{"new":true}', H.vfs_read(CFG))
        assert.equal(SB_OK, H.vfs_read(BAK))
        assert_no_stages()
    end)

    it("uses native exit success even when sing-box check prints a diagnostic", function()
        local SBX = begin_sbx({ check = "validation notice\n\nPT_EXIT:0\n" })
        assert_restart(SBX.save_config('{"new":true}'))
        assert.equal('{"new":true}', H.vfs_read(CFG))
        assert.equal(SB_OK, H.vfs_read(BAK))
    end)

    it("does not treat a current-config validation-stage IO failure as invalid source content", function()
        local SBX = begin_sbx({ failures = { [CFG .. ".tmp-check.*"] = { close = true } } })
        H.vfs_write(BAK, SB_ORIG)
        local r = SBX.save_config(SB_PATCHED)
        assert.is_false(r.success)
        assert.truthy(r.error)
        assert.falsy(r.applied)
        assert.equal(SB_OK, H.vfs_read(CFG))
        assert.equal(SB_ORIG, H.vfs_read(BAK))
        assert.equal(0, #commands_containing("/etc/init.d/sing-box restart"))
        assert_no_stages()
    end)

    it("retains complete infrastructure-check diagnostics while validating the backup source", function()
        local details = string.rep("native checker infrastructure failure\n", 100)
        local SBX = begin_sbx({ popen = { { match = function(cmd)
            return cmd:find("sing-box check -c ", 1, true) and cmd:find(CFG .. ".tmp-check.", 1, true)
        end, out = details .. "\nPT_EXIT:2\n" } } })
        H.vfs_write(BAK, SB_ORIG)
        local r = SBX.save_config(SB_PATCHED)
        assert.is_false(r.success)
        assert.equal("Cannot create backup", r.error)
        assert.falsy(r.applied)
        assert.equal("string", type(r.details))
        assert.truthy(r.details:find(details, 1, true), "backup infrastructure errors must retain the entire checker output")
        assert.equal(SB_OK, H.vfs_read(CFG))
        assert.equal(SB_ORIG, H.vfs_read(BAK))
        assert.equal(0, #commands_containing("/etc/init.d/sing-box restart"))
        assert_no_stages()
    end)

    for _, case in ipairs({
        { name = "native check failure", output = "decode error: bad config\n\nPT_EXIT:1\n" },
        { name = "quiet nonzero check", output = "\nPT_EXIT:1\n" },
        { name = "missing exit evidence", output = "" }
    }) do
        it("rejects " .. case.name .. " without changing live/backup bytes", function()
            local SBX = begin_sbx({ check = case.output })
            H.vfs_write(BAK, SB_ORIG)
            local r = SBX.import_config('{"candidate":true}')
            assert.truthy(r.error)
            assert.falsy(r.success)
            assert.falsy(r.applied)
            if case.name == "native check failure" then assert.equal("decode error: bad config\n", r.details) end
            assert.equal(SB_OK, H.vfs_read(CFG))
            assert.equal(SB_ORIG, H.vfs_read(BAK))
            assert.equal(0, #commands_containing("/etc/init.d/sing-box restart"))
            assert_no_stages()
        end)
    end

    it("reports failed restart as disk-applied, never replays and retains full diagnostics", function()
        local details = string.rep("restart failed\n", 200)
        local SBX = begin_sbx({ popen = {
            service_reply("restart", details .. "\nPT_EXIT:17\n"),
            pid_reply("55\nPT_EXIT:0\n")
        } })
        H.vfs_write("/proc/55/stat", "55 (sing-box) S " .. string.rep("0 ", 18) .. "400\n")
        local r = SBX.save_config('{"new":true}')
        assert.is_false(r.success)
        assert.is_true(r.applied)
        assert.is_true(r.verification_required)
        assert.is_true(r.previous_running)
        assert.is_true(r.previous_identity_known)
        assert.equal("55:400", r.previous_instance)
        assert.truthy(r.error)
        assert.equal(details, r.details)
        assert.equal('{"new":true}', H.vfs_read(CFG))
        assert.equal(SB_OK, H.vfs_read(BAK))
        assert.equal(1, #commands_containing("/etc/init.d/sing-box restart"))
    end)

    it("forwards the complete apply response and Save-only skip option", function()
        local SBX = begin_sbx()
        local SRV = require("podkop-tweaker.services")
        local result = { success = false, applied = true, error = "restart failed", details = "complete output\n",
            verification_required = true, previous_running = true, previous_identity_known = true, previous_instance = "55:400" }
        local options_seen = {}
        SRV.apply_service = function(svc, content, options)
            assert.equal(SRV.singbox, svc)
            assert.equal(SB_OK, content)
            options_seen[#options_seen + 1] = options or {}
            return result
        end
        assert.equal(result, SBX.save_config(SB_OK))
        assert.is_true(options_seen[1].skip_unchanged)
        assert.equal(result, SBX.import_config(SB_OK))
        assert.falsy(options_seen[2].skip_unchanged)
    end)
end)

describe("api_singbox service status/toggle/rollback", function()
    it("exposes a running instance, known absence and failed query distinctly", function()
        local SBX = begin_sbx({ popen = { pid_reply("55\nPT_EXIT:0\n") } })
        H.vfs_write("/proc/55/stat", "55 (sing-box) S " .. string.rep("0 ", 18) .. "400\n")
        local r = SBX.service_status()
        assert.is_true(r.running)
        assert.equal("55", r.pid)
        assert.equal("55:400", r.instance)
        H.finish()
        SBX = begin_sbx()
        assert.is_false(SBX.service_status().running)
        H.finish()
        SBX = begin_sbx({ popen = { pid_reply("\nPT_EXIT:2\n") } })
        local unknown = SBX.service_status()
        assert.truthy(unknown.error)
        assert.is_nil(unknown.running)
    end)

    it("does not claim success on quiet nonzero toggle commands", function()
        local SBX = begin_sbx({ popen = { service_reply("start", "\nPT_EXIT:1\n") } })
        assert.same({ success = false, error = "Invalid action" }, SBX.service_toggle("reload"))
        local r = SBX.service_toggle("start")
        assert.is_false(r.success)
        assert.truthy(r.error)
        assert.is_true(SBX.service_toggle("stop").success)
        assert.equal(1, #commands_containing(SERVICE_COMMANDS.start))
        assert.equal(1, #commands_containing(SERVICE_COMMANDS.stop))
    end)

    it("does not label a failed service command applied merely because lock release fails", function()
        local SBX = begin_sbx({ popen = { service_reply("start", "start failed\n\nPT_EXIT:1\n") },
            failures = { ["/var/lock/podkop-fragment.lock"] = { rmdir = true } } })
        local r = SBX.service_toggle("start")
        assert.is_false(r.success)
        assert.truthy(r.error)
        assert.falsy(r.applied)
        assert.is_true(r.unknown)
        assert.equal(SB_OK, H.vfs_read(CFG))
        assert.equal(1, #commands_containing(SERVICE_COMMANDS.start))
    end)

    it("restores a checked backup and forwards the checked restart response", function()
        local SBX = begin_sbx()
        assert.equal("Backup file not found", SBX.rollback().error)
        H.vfs_write(BAK, SB_ORIG)
        H.vfs_write(CFG, "broken")
        assert_restart(SBX.rollback())
        assert.equal(SB_ORIG, H.vfs_read(CFG))
        assert.equal(1, #commands_containing("/etc/init.d/sing-box restart"))
    end)

    it("does not label a missing-backup rollback applied when lock release fails", function()
        local SBX = begin_sbx({ failures = { ["/var/lock/podkop-fragment.lock"] = { rmdir = true } } })
        local r = SBX.rollback()
        assert.is_false(r.success)
        assert.truthy(r.error)
        assert.falsy(r.applied)
        assert.is_true(r.unknown)
        assert.equal(SB_OK, H.vfs_read(CFG))
        assert.is_nil(H.vfs_read(BAK))
        assert.equal(0, #commands_containing("/etc/init.d/sing-box restart"))
    end)

    for _, case in ipairs({
        { name = "Save", action = "restart", applied = true,
            run = function(api) return api.save_config(SB_PATCHED) end, live = SB_PATCHED, backup = SB_OK },
        { name = "Toggle", action = "start", applied = false,
            run = function(api) return api.service_toggle("start") end, live = SB_OK, backup = SB_ORIG },
        { name = "Rollback", action = "restart", applied = true,
            run = function(api) return api.rollback() end, live = SB_ORIG, backup = SB_ORIG }
    }) do
        it("preserves the primary " .. case.name .. " failure evidence when resource release also fails", function()
            local details = string.rep("complete " .. case.name .. " service failure\n", 100)
            local SBX = begin_sbx({ popen = { service_reply(case.action, details .. "\nPT_EXIT:7\n"), pid_reply("55\nPT_EXIT:0\n") },
                failures = { ["/var/lock/podkop-fragment.lock"] = { rmdir = true } } })
            H.vfs_write("/proc/55/stat", "55 (sing-box) S " .. string.rep("0 ", 18) .. "400\n")
            H.vfs_write(BAK, SB_ORIG)
            local r = case.run(SBX)
            assert.is_false(r.success)
            assert.is_true(r.unknown)
            assert.equal(case.applied, r.applied == true)
            assert.truthy(r.error)
            assert.equal("string", type(r.details))
            assert.truthy(r.details:find(details, 1, true), "lock-release reporting must not replace the primary diagnostics")
            if case.applied then
                assert.is_true(r.verification_required)
                assert.is_true(r.previous_running)
                assert.is_true(r.previous_identity_known)
                assert.equal("55:400", r.previous_instance)
            end
            assert.equal(case.live, H.vfs_read(CFG))
            assert.equal(case.backup, H.vfs_read(BAK))
            assert.equal(1, #commands_containing(SERVICE_COMMANDS[case.action]), "release failure must not replay the mutation")
            assert_no_stages()
        end)
    end
end)

describe("api_singbox.outbounds SB2 (controlled jq, not native filter execution)", function()
    for _, empty in ipairs({ '[]', '{}' }) do
        it("accepts explicit count zero with an empty " .. empty .. " container", function()
            local SBX = begin_sbx({ popen = { jq_out('{"outbound_count":0,"outbounds":' .. empty .. '}') } })
            assert.same({ outbound_count = 0, outbounds = {} }, SBX.outbounds())
            assert.equal(SB_OK, H.vfs_read(CFG))
            assert.is_nil(H.vfs_read(BAK))
            assert.equal(0, #commands_containing("/etc/init.d/sing-box restart"))
            assert_no_stages()
        end)
    end

    it("parses compact actual JSON with escaped quotes, slashes and control escapes", function()
        local rows = {
            { tag = 'a"quoted', type = "direct", server = "server\\path\nname", tls_enabled = false, has_fragment = false },
            { tag = "b", type = "vmess", server = "server\\path\nname", tls_enabled = true, has_fragment = true }
        }
        local expected = { outbound_count = 2, outbounds = rows }
        local SBX = begin_sbx({ popen = { jq_out(H.json.stringify(expected)) } })
        assert.same(expected, SBX.outbounds())
    end)

    for _, raw in ipairs({
        "", "garbage", "[]", '{"outbounds":{}}', '{"error":"jq failed"}',
        '{"success":false,"outbound_count":0,"outbounds":[]}',
        '{"success":"yes","outbound_count":0,"outbounds":[]}',
        '{"outbound_count":1,"outbounds":{}}', '{"outbound_count":0,"outbounds":{"bad":1}}',
        '{"outbound_count":-1,"outbounds":[]}', '{"outbound_count":true,"outbounds":[]}',
        '{"outbound_count":1,"outbounds":[{}]}',
        '{"outbound_count":1,"outbounds":[{"tag":"x","type":"","server":"s","tls_enabled":true,"has_fragment":false}]}',
        '{"outbound_count":1,"outbounds":[{"tag":"bad;tag","type":"vless","server":"s","tls_enabled":true,"has_fragment":false}]}',
        '{"outbound_count":1,"outbounds":[{"tag":"x","type":"vless","server":"s","tls_enabled":false,"has_fragment":false,"error":"failed"}]}',
        '{"outbound_count":1,"outbounds":[{"tag":"x","type":"vless","server":"s","tls_enabled":"true","has_fragment":false}]}',
        '{"outbound_count":2,"outbounds":[{"tag":"x","type":"vless","server":"s","tls_enabled":true,"has_fragment":false},null]}'
    }) do
        it("does not normalize malformed/non-list jq output into valid empty outbounds: " .. raw, function()
            local SBX = begin_sbx({ popen = { jq_out(raw) } })
            assert_outbounds_error(SBX.outbounds())
            assert.equal(SB_OK, H.vfs_read(CFG))
            assert_no_stages()
        end)
    end

    it("checks jq status even when stdout looks like a valid empty result", function()
        local details = '{"outbound_count":0,"outbounds":[]}\n' .. string.rep("jq failed\n", 100)
        local SBX = begin_sbx({ popen = { jq_out(details, 23) } })
        local r = SBX.outbounds()
        assert_outbounds_error(r)
        assert.equal(details, r.details)
        assert_no_stages()
    end)

    it("rejects quiet nonzero jq and absent exit evidence", function()
        local SBX = begin_sbx({ popen = { jq_out("", 4) } })
        assert_outbounds_error(SBX.outbounds())
        H.finish()
        SBX = begin_sbx({ popen = { { match = "jq ", out = '{"outbound_count":0,"outbounds":[]}' } } })
        assert_outbounds_error(SBX.outbounds())
    end)

    for _, operation in ipairs({ "open", "read", "close" }) do
        it("reports config " .. operation .. " failure before jq", function()
            local SBX = begin_sbx({ failures = { [CFG] = { [operation] = true, errno = 13 } } })
            assert_outbounds_error(SBX.outbounds())
            assert.equal(0, #commands_containing("jq "))
            assert.equal(SB_OK, H.vfs_read(CFG))
        end)
    end

    for _, source in ipairs({ "", " \n\t", "[]", "{} {}", "false", '{"outbounds":' }) do
        it("rejects a non-single-object source: " .. source, function()
            local SBX = begin_sbx()
            H.vfs_write(CFG, source)
            assert_outbounds_error(SBX.outbounds())
            assert.equal(0, #commands_containing("jq "))
            assert.equal(source, H.vfs_read(CFG))
        end)
    end

    it("keeps missing/oversize and snapshot-write failures explicit", function()
        local SBX = begin_sbx({ seed_cfg = false })
        assert_outbounds_error(SBX.outbounds())
        H.vfs_write(CFG, string.rep("x", 2097153))
        assert_outbounds_error(SBX.outbounds())
        H.vfs_write(CFG, SB_OK)
        H.state().failures[CFG .. ".tmp-read.*"] = { write = true, partial = 5 }
        assert_outbounds_error(SBX.outbounds())
        assert.equal(0, #commands_containing("jq "))
        assert_no_stages()
    end)

    it("reads one immutable bounded snapshot and carries native single-object/array guards", function()
        local changed = '{"outbounds":[]}'
        local SBX = begin_sbx({ popen = { { match = "jq ", out = function(cmd)
            local stage = cmd:match("'(/etc/sing%-box/config%.json%.tmp%-read%.[^']+)'")
            assert.truthy(stage)
            assert.equal(SB_OK, H.vfs_read(stage))
            assert.equal("600", H.vfs_mode(stage))
            assert.truthy(cmd:find("jq -c -e -s", 1, true))
            assert.truthy(cmd:find('length == 1 and (.[0] | type == "object")', 1, true))
            assert.truthy(cmd:find('(.outbounds | type) != "array"', 1, true))
            assert.truthy(cmd:find('.tls.record_fragment // false', 1, true))
            H.vfs_write(CFG, changed)
            return '{"outbound_count":0,"outbounds":[]}\nPT_EXIT:0\n'
        end } } })
        assert.same({ outbound_count = 0, outbounds = {} }, SBX.outbounds())
        assert.equal(changed, H.vfs_read(CFG), "a read query must never restore or modify live bytes")
        assert.is_nil(H.vfs_read(BAK))
        assert_no_stages()
    end)

    it("does not report a source-shape jq error as a legitimate empty list", function()
        local SBX = begin_sbx({ popen = { jq_out("Config outbounds must be an array\n", 5) } })
        H.vfs_write(CFG, '{"outbounds":{}}')
        assert_outbounds_error(SBX.outbounds())
        assert.equal('{"outbounds":{}}', H.vfs_read(CFG))
    end)

    for _, jq_failed in ipairs({ false, true }) do
        it("requires owned snapshot cleanup before returning " .. (jq_failed and "a jq failure" or "a successful query"), function()
            local details = jq_failed and string.rep("jq diagnostic\n", 100) or '{"outbound_count":0,"outbounds":[]}'
            local SBX = begin_sbx({ popen = { jq_out(details, jq_failed and 5 or 0) },
                failures = { [CFG .. ".tmp-read.*"] = { remove = true } } })
            H.vfs_write(CFG .. ".tmp-read.foreign", "another invocation")
            local r = SBX.outbounds()
            assert_outbounds_error(r)
            assert.is_true(r.cleanup_failed)
            assert.equal(jq_failed and "Cannot enumerate outbounds" or "Cannot clean up config snapshot", r.error)
            if jq_failed then assert.equal(details, r.details:sub(1, #details)) end
            local stage = H.last_stage(CFG .. ".tmp-read.*")
            assert.truthy(stage)
            assert.equal(SB_OK, H.vfs_read(stage), "the failed cleanup remains an owned stage for inspection")
            assert.truthy(r.details:find(stage, 1, true))
            assert.truthy(r.details:find("Injected remove failure", 1, true))
            assert.equal("another invocation", H.vfs_read(CFG .. ".tmp-read.foreign"))
            assert.equal(SB_OK, H.vfs_read(CFG))
            assert.is_nil(H.vfs_read(BAK))
            assert.equal(1, #commands_containing("jq "), "failed cleanup must not replay the query")
            H.state().failures[CFG .. ".tmp-read.*"] = nil
            assert.is_true(require("podkop-tweaker.services").discard_stage(stage))
            assert_no_stages()
        end)
    end
end)

describe("api_singbox.patch_fragment resource coordination", function()
    it("preserves tag/method/delay validation", function()
        local SBX = begin_sbx()
        assert.same({ error = "No outbounds selected" }, SBX.patch_fragment("zz"))
        assert.same({ error = "No outbounds selected" }, SBX.patch_fragment("[]"))
        assert.same({ error = "Invalid tag value" }, SBX.patch_fragment("[1]"))
        assert.same({ error = "Invalid tag value" }, SBX.patch_fragment('["bad;tag"]'))
        assert.same({ error = "Select at least one fragment method" }, SBX.patch_fragment('["proxy"]', "apply"))
        assert.same({ error = "Invalid fallback_delay format" }, SBX.patch_fragment('["proxy"]', "apply", "1", nil, "abc"))
        assert.equal(0, #commands_containing("jq "))
    end)

    it("reports missing source rather than patching a default configuration", function()
        local SBX = begin_sbx({ seed_cfg = false })
        assert.equal("Cannot read config", SBX.patch_fragment('["proxy"]', "apply", "1", "1").error)
        assert.equal(0, #commands_containing("/etc/init.d/sing-box restart"))
    end)

    it("does not steal a busy shared shell lock or perform jq before acquisition", function()
        local SBX = begin_sbx()
        H.vfs_mkdir("/var/lock/podkop-fragment.lock")
        local r = SBX.patch_fragment('["proxy"]', "remove")
        assert.is_false(r.success)
        assert.truthy(r.error)
        assert.falsy(r.applied)
        assert.is_true(H.vfs_exists("/var/lock/podkop-fragment.lock"))
        assert.equal(0, #commands_containing("jq "))
        assert.equal(SB_OK, H.vfs_read(CFG))
    end)

    for _, release_failed in ipairs({ false, true }) do
        it("does not apply a patch after snapshot cleanup fails" .. (release_failed and " even if lock release also fails" or ""), function()
            local failures = { [CFG .. ".tmp-read.*"] = { remove = true } }
            if release_failed then failures["/var/lock/podkop-fragment.lock"] = { rmdir = true } end
            local SBX = begin_sbx({ popen = { jq_out(SB_PATCHED) }, failures = failures })
            H.vfs_write(BAK, SB_ORIG)
            local r = SBX.patch_fragment('["proxy"]', "remove")
            assert.is_false(r.success)
            assert.is_true(r.cleanup_failed)
            assert.falsy(r.applied, "a failed read-only snapshot cleanup is not a disk-applied patch")
            assert.equal(release_failed or nil, r.unknown)
            assert.truthy(r.details:find("Injected remove failure", 1, true))
            assert.equal(SB_OK, H.vfs_read(CFG))
            assert.equal(SB_ORIG, H.vfs_read(BAK))
            assert.equal(0, #commands_containing("sing-box check"))
            assert.equal(0, #commands_containing("/etc/init.d/sing-box restart"))
            local stage = H.last_stage(CFG .. ".tmp-read.*")
            assert.equal(SB_OK, H.vfs_read(stage))
            H.state().failures[CFG .. ".tmp-read.*"] = nil
            assert.is_true(require("podkop-tweaker.services").discard_stage(stage))
        end)
    end

    it("holds the shared shell/API resource through snapshot, jq and reentrant checked application", function()
        local competing
        local SBX = begin_sbx({ popen = { { match = "jq ", out = function(cmd)
            assert.is_true(H.vfs_exists("/var/lock/podkop-fragment.lock"))
            local stage = cmd:match("'(/etc/sing%-box/config%.json%.tmp%-read%.[^']+)'")
            assert.equal(SB_OK, H.vfs_read(stage))
            local actor = coroutine.create(function()
                competing = require("podkop-tweaker.services").apply_service("singbox", '{"competing":true}', { restart = false })
            end)
            local resumed, err = coroutine.resume(actor)
            assert.is_true(resumed, tostring(err))
            assert.truthy(competing.error)
            assert.falsy(competing.success)
            assert.equal(SB_OK, H.vfs_read(CFG))
            return '{"patched":true}\nPT_EXIT:0\n'
        end } } })
        assert_restart(SBX.patch_fragment('["proxy","alt"]', "remove"))
        assert.equal('{"patched":true}', H.vfs_read(CFG))
        assert.equal(SB_OK, H.vfs_read(BAK))
        assert.is_false(H.vfs_exists("/var/lock/podkop-fragment.lock"))
        local cmd = commands_containing("jq ")[1]
        assert.truthy(cmd:find("--arg t1 'proxy'", 1, true))
        assert.truthy(cmd:find("--arg t2 'alt'", 1, true))
        assert.truthy(cmd:find("del(.fragment, .record_fragment, .fragment_fallback_delay)", 1, true))
        assert_no_stages()
    end)

    it("keeps both-method and record-only transformations and unique repeated snapshots", function()
        local SBX = begin_sbx({ popen = { jq_out(SB_PATCHED) } })
        assert_restart(SBX.patch_fragment('["proxy"]', "apply", "1", "1", "700ms"))
        local both = commands_containing("jq ")[1]
        assert.truthy(both:find('"fragment": true', 1, true))
        assert.truthy(both:find('"record_fragment": (true)', 1, true))
        assert.truthy(both:find('"fragment_fallback_delay": "700ms"', 1, true))
        assert_restart(SBX.patch_fragment('["proxy"]', "apply", nil, "1"))
        local record = commands_containing("jq ")[2]
        assert.truthy(record:find('"fragment": false', 1, true))
        assert.truthy(record:find('"record_fragment": true', 1, true))
        assert.truthy(record:find('del(.fragment_fallback_delay)', 1, true))
        assert.falsy(record:find('"fragment_fallback_delay": "', 1, true))
        local paths = H.stage_paths(CFG .. ".tmp-read.*")
        assert.equal(2, #paths)
        assert.not_equal(paths[1], paths[2])
        assert_no_stages()
    end)

    it("does not overwrite an external source change made during jq", function()
        local changed = '{"external":true}'
        local SBX = begin_sbx({ popen = { { match = "jq ", out = function()
            H.vfs_write(CFG, changed)
            return '{"patched":true}\nPT_EXIT:0\n'
        end } } })
        H.vfs_write(BAK, SB_ORIG)
        local r = SBX.patch_fragment('["proxy"]', "remove")
        assert.equal("Config changed during patch", r.error)
        assert.equal(changed, H.vfs_read(CFG))
        assert.equal(SB_ORIG, H.vfs_read(BAK))
        assert.equal(0, #commands_containing("/etc/init.d/sing-box restart"))
        assert_no_stages()
    end)

    for _, case in ipairs({
        { name = "empty jq", output = "", code = 0 }, { name = "quiet nonzero jq", output = "", code = 9 },
        { name = "non-object jq", output = "[]", code = 0 }, { name = "failed jq with JSON stdout", output = '{"patched":true}', code = 1 }
    }) do
        it("keeps config/backup unchanged on " .. case.name, function()
            local SBX = begin_sbx({ popen = { jq_out(case.output, case.code) } })
            H.vfs_write(BAK, SB_ORIG)
            assert.equal("jq patch failed", SBX.patch_fragment('["proxy"]', "remove").error)
            assert.equal(SB_OK, H.vfs_read(CFG))
            assert.equal(SB_ORIG, H.vfs_read(BAK))
            assert.equal(0, #commands_containing("/etc/init.d/sing-box restart"))
            assert_no_stages()
        end)
    end

    it("retains native check failure details and the previous backup", function()
        local details = string.rep("bad after patch\n", 100)
        local SBX = begin_sbx({ popen = { jq_out('{"patched":true}') }, check = details .. "\nPT_EXIT:1\n" })
        H.vfs_write(BAK, SB_ORIG)
        local r = SBX.patch_fragment('["proxy"]', "remove")
        assert.equal("sing-box check failed after patch", r.error)
        assert.equal(details, r.details)
        assert.equal(SB_OK, H.vfs_read(CFG))
        assert.equal(SB_ORIG, H.vfs_read(BAK))
        assert_no_stages()
    end)

    it("makes one owned backup and rejects a failed backup close before publication/restart", function()
        local SBX = begin_sbx({ popen = { jq_out('{"patched":true}') } })
        assert.is_true(SBX.patch_fragment('["proxy"]', "remove").success)
        local writes = 0
        for _, call in ipairs(H.state().io_log) do
            if call.operation == "write" and call.path:find(BAK .. ".", 1, true) == 1 then writes = writes + 1 end
        end
        assert.equal(1, writes)
        H.finish()
        SBX = begin_sbx({ popen = { jq_out('{"patched":true}') }, failures = { [BAK .. ".*"] = { close = true } } })
        H.vfs_write(BAK, SB_ORIG)
        assert.truthy(SBX.patch_fragment('["proxy"]', "remove").error)
        assert.equal(SB_OK, H.vfs_read(CFG))
        assert.equal(SB_ORIG, H.vfs_read(BAK))
        assert.equal(0, #commands_containing("/etc/init.d/sing-box restart"))
        assert_no_stages()
    end)

    it("preserves disk-applied/restart-failed semantics for Fragment too", function()
        local SBX = begin_sbx({ popen = { jq_out('{"patched":true}'),
            service_reply("restart", "\nPT_EXIT:1\n") } })
        local r = SBX.patch_fragment('["proxy"]', "remove")
        assert.is_false(r.success)
        assert.is_true(r.applied)
        assert.truthy(r.error)
        assert.equal('{"patched":true}', H.vfs_read(CFG))
        assert.equal(SB_OK, H.vfs_read(BAK))
        assert.equal(1, #commands_containing("/etc/init.d/sing-box restart"))
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

    it("does not mistake a marker outside managed service functions for an active wrapper", function()
        local SBX = begin_sbx({})
        H.vfs_write(ORIG, "orig")
        H.vfs_write(INIT_PODKOP, "podkop-fragment-patch.sh\n")
        assert.same({ installed = true, stale = true }, SBX.wrapper_status())
    end)

    it("keeps the response shape for the detached start/reload hook pair", function()
        local SBX = begin_sbx({})
        H.vfs_write(ORIG, wrapper_init(0, 0))
        H.vfs_write(INIT_PODKOP, wrapper_init(1, 1))
        assert.same({ installed = true, stale = false }, SBX.wrapper_status())
    end)

    for _, case in ipairs({
        { name = "legacy pair", start = { LEGACY_HOOK }, reload = { LEGACY_HOOK } },
        { name = "mixed pair", start = { OWNED_HOOK }, reload = { LEGACY_HOOK } },
        { name = "reverse mixed pair", start = { LEGACY_HOOK }, reload = { OWNED_HOOK } },
        { name = "legacy start only", start = { LEGACY_HOOK }, reload = {} },
        { name = "legacy duplicates", start = { LEGACY_HOOK, LEGACY_HOOK }, reload = { LEGACY_HOOK }, duplicate_hooks = true },
        { name = "mixed duplicates", start = { LEGACY_HOOK, OWNED_HOOK }, reload = { OWNED_HOOK, LEGACY_HOOK }, duplicate_hooks = true }
    }) do
        it("marks " .. case.name .. " stale without mutating or replaying a repair", function()
            local SBX = begin_sbx()
            local original, current = wrapper_init(0, 0), wrapper_init(case.start, case.reload)
            H.vfs_write(ORIG, original)
            H.vfs_write(INIT_PODKOP, current)
            local expected = { installed = true, stale = true, duplicate_hooks = case.duplicate_hooks }
            assert.same(expected, SBX.wrapper_status())
            assert.same(expected, SBX.wrapper_status())
            assert.equal(original, H.vfs_read(ORIG))
            assert.equal(current, H.vfs_read(INIT_PODKOP))
            assert.same({}, H.exec_cmds())
            assert.same({}, H.popen_cmds())
            assert.same({}, H.execute_cmds())
            assert.same({}, H.commits())
        end)
    end

    for _, managed in ipairs({ "start_service", "reload_service" }) do
        for _, case in ipairs({
            { name = "one detached hook", hooks = { OWNED_HOOK } },
            { name = "one legacy hook", hooks = { LEGACY_HOOK } },
            { name = "two detached hooks", hooks = { OWNED_HOOK, OWNED_HOOK }, duplicate_hooks = true },
            { name = "two legacy hooks", hooks = { LEGACY_HOOK, LEGACY_HOOK }, duplicate_hooks = true },
            { name = "mixed hooks", hooks = { OWNED_HOOK, LEGACY_HOOK }, duplicate_hooks = true }
        }) do
            it("requires both functions when only " .. managed .. " has " .. case.name, function()
                local SBX = begin_sbx()
                local original = wrapper_init(0, 0)
                local current = wrapper_init(managed == "start_service" and case.hooks or {}, managed == "reload_service" and case.hooks or {})
                H.vfs_write(ORIG, original)
                H.vfs_write(INIT_PODKOP, current)
                assert.same({ installed = true, stale = true, duplicate_hooks = case.duplicate_hooks }, SBX.wrapper_status())
                assert.equal(current, H.vfs_read(INIT_PODKOP))
                assert.equal(original, H.vfs_read(ORIG))
                assert.same({}, H.exec_cmds())
                assert.same({}, H.popen_cmds())
                assert.same({}, H.execute_cmds())
                assert.same({}, H.commits())
            end)
        end
    end

    it("reports six generated hook lines as duplicates without changing installed/stale", function()
        local SBX = begin_sbx({})
        H.vfs_write(ORIG, wrapper_init(0, 0))
        H.vfs_write(INIT_PODKOP, wrapper_init(3, 3))
        assert.same({ installed = true, stale = false, duplicate_hooks = true }, SBX.wrapper_status())
    end)

    for _, managed in ipairs({ "start_service", "reload_service" }) do
        for _, body in ipairs({ LEGACY_HOOK, OWNED_HOOK }) do
            it("reports an owned hook in original " .. managed .. " with a normal detached current pair: " .. body, function()
                local SBX = begin_sbx({})
                H.vfs_write(ORIG, wrapper_init(managed == "start_service" and 1 or 0, managed == "reload_service" and 1 or 0, body))
                H.vfs_write(INIT_PODKOP, wrapper_init(1, 1))
                assert.same({ installed = true, stale = false, duplicate_hooks = true }, SBX.wrapper_status())
            end)
        end
    end

    it("counts mixed owned hooks in the original independently of the current init", function()
        local SBX = begin_sbx()
        H.vfs_write(ORIG, wrapper_init({ LEGACY_HOOK, OWNED_HOOK }, {}))
        H.vfs_write(INIT_PODKOP, wrapper_init(1, 1))
        assert.same({ installed = true, stale = false, duplicate_hooks = true }, SBX.wrapper_status())
    end)

    it("retains stale=true when the original contains a hook but the current init has none", function()
        local SBX = begin_sbx({})
        H.vfs_write(ORIG, wrapper_init(1, 0))
        H.vfs_write(INIT_PODKOP, wrapper_init(0, 0))
        assert.same({ installed = true, stale = true, duplicate_hooks = true }, SBX.wrapper_status())
    end)

    it("does not classify identical calls in unrelated administrator functions as generated service hooks", function()
        local SBX = begin_sbx({})
        local custom = "\ncustom_refresh() {\n\t" .. LEGACY_HOOK .. "\n\t" .. OWNED_HOOK .. "\n}\n" ..
            LEGACY_HOOK .. "\n" .. OWNED_HOOK .. "\n"
        H.vfs_write(ORIG, wrapper_init(0, 0) .. custom)
        H.vfs_write(INIT_PODKOP, wrapper_init(1, 1) .. custom)
        assert.same({ installed = true, stale = false }, SBX.wrapper_status())
    end)

    it("does not count comments or manual patch invocations as generated hooks", function()
        local SBX = begin_sbx({})
        local mentions = "\n# " .. LEGACY_HOOK .. "\n# " .. OWNED_HOOK .. "\n/usr/bin/podkop-fragment-patch.sh --manual\n"
        H.vfs_write(ORIG, wrapper_init(0, 0) .. mentions)
        H.vfs_write(INIT_PODKOP, wrapper_init(1, 1) .. mentions)
        assert.same({ installed = true, stale = false }, SBX.wrapper_status())
    end)

    it("trims only surrounding hook whitespace and leaves near-matches unmanaged", function()
        local SBX = begin_sbx()
        local current = wrapper_init({ "  " .. OWNED_HOOK .. "\t", LEGACY_HOOK .. " # administrator-owned" }, { OWNED_HOOK })
        local original = wrapper_init({ OWNED_HOOK .. " # administrator-owned" }, {})
        H.vfs_write(ORIG, original)
        H.vfs_write(INIT_PODKOP, current)
        assert.same({ installed = true, stale = false }, SBX.wrapper_status())
        assert.equal(current, H.vfs_read(INIT_PODKOP))
        assert.equal(original, H.vfs_read(ORIG))
        assert.same({}, H.popen_cmds())
    end)

    it("marks an installed wrapper stale when the current init is missing", function()
        local SBX = begin_sbx({})
        H.vfs_write(ORIG, wrapper_init(0, 0))
        assert.same({ installed = true, stale = true }, SBX.wrapper_status())
    end)

    it("does not claim installation from a lone current-init marker without an original", function()
        local SBX = begin_sbx({})
        H.vfs_write(INIT_PODKOP, wrapper_init(1, 0))
        assert.same({ installed = false, stale = false }, SBX.wrapper_status())
    end)

    for _, path in ipairs({ ORIG, INIT_PODKOP }) do
        it("does not turn an unreadable wrapper status source into installed/stale facts: " .. path, function()
            local SBX = begin_sbx({ failures = { [path] = { close = true } } })
            H.vfs_write(ORIG, wrapper_init(0, 0))
            H.vfs_write(INIT_PODKOP, wrapper_init(1, 1))
            local r = SBX.wrapper_status()
            assert.truthy(r.error)
            assert.truthy(r.details)
            assert.is_nil(r.installed)
            assert.is_nil(r.stale)
        end)
    end
end)

describe("api_singbox.wrapper_toggle", function()
    local function exit_responder(out)
        return { match = function(cmd)
            local checked = require("podkop-tweaker.services").checked_command
            return cmd == checked("/etc/init.d/podkop-fragment enable") or cmd == checked("/etc/init.d/podkop-fragment disable")
        end, out = out }
    end

    local function assert_checked_call(action)
        assert.equal(1, #H.popen_cmds(), "wrapper mutation must use one direct pipe, without automatic replay")
        local command = H.popen_cmds()[1]
        assert.equal(require("podkop-tweaker.services").checked_command("/etc/init.d/podkop-fragment " .. action), command)
        assert.truthy(command:find(") </dev/null 2>&1;", 1, true), "stdin must be occupied before the service command starts")
        assert.truthy(command:find("printf '\\nPT_EXIT:%s\\n' \"$?\"", 1, true), "capture the checked command's actual exit status")
        assert.same({}, H.exec_cmds(), "checked wrapper commands must not pass through luci.sys.exec")
    end

    local function assert_no_lua_mutation()
        assert.same({}, H.execute_cmds(), "Lua must not remove or replace podkop.orig before shell normalization")
        for _, call in ipairs(H.state().io_log) do
            assert.not_equal("write", call.operation)
            if call.operation == "open" then assert.matches("^r", call.mode) end
        end
        assert.same({}, H.commits())
    end

    it("invalid action rejected", function()
        local SBX = begin_sbx({})
        assert.same({ error = "Invalid action" }, SBX.wrapper_toggle("toggle", nil, nil, nil))
        assert.equal(0, #H.exec_cmds())
        assert.equal(0, #H.popen_cmds())
    end)

    it("enable stores uci settings (bad delay coerced) and reports installed", function()
        local SBX = begin_sbx({ popen = { exit_responder("\nPT_EXIT:0\n") } })
        H.vfs_write(ORIG, "created-by-script")
        local r = SBX.wrapper_toggle("enable", "1", nil, "abc", nil)
        assert.same({ success = true, installed = true }, r)
        assert.same({ "podkop-fragment" }, H.commits())
        local uci = require("luci.model.uci").cursor()
        assert.equal("true", uci:get("podkop-fragment", "settings", "fragment"))
        assert.equal("false", uci:get("podkop-fragment", "settings", "record_fragment"))
        assert.equal("500ms", uci:get("podkop-fragment", "settings", "fragment_fallback_delay"))
        assert_checked_call("enable")
    end)

    it("disable touches no uci", function()
        local SBX = begin_sbx({ popen = { exit_responder("\nPT_EXIT:0\n") } })
        local r = SBX.wrapper_toggle("disable", nil, nil, nil)
        assert.same({ success = true, installed = false }, r)
        assert.equal(0, #H.commits())
        assert_checked_call("disable")
    end)

    it("reinstall leaves the original and all UCI, including enabled=0, to the shell normalizer", function()
        local original, current = wrapper_init(0, 0), wrapper_init({ LEGACY_HOOK, OWNED_HOOK }, { OWNED_HOOK, LEGACY_HOOK })
        local saved_uci = {
            ["podkop-fragment"] = {
                H.sec("settings", "fragment", {
                    enabled = "0", fragment = "true", record_fragment = "false", fragment_fallback_delay = "750ms",
                    singbox_config = "/etc/sing-box/custom.json", log_file = "/var/log/custom-fragment.log",
                    log_max_lines = "75", unknown_option = "keep", custom_list = { "first", "second" }
                }),
                H.sec("extra", "custom", { value = "also keep" })
            },
            podkop = { H.sec("main", "settings", { value = "unrelated" }) }
        }
        local called = false
        local SBX = begin_sbx({ uci = H.json.parse(H.json.stringify(saved_uci)), popen = { exit_responder(function()
            called = true
            assert.equal(original, H.vfs_read(ORIG), "the original must still exist when the shell command starts")
            assert.equal(current, H.vfs_read(INIT_PODKOP))
            assert.same(saved_uci, H.state().uci)
            assert_no_lua_mutation()
            return "\nPT_EXIT:0\n"
        end) } })
        H.vfs_write(ORIG, original)
        H.vfs_write(INIT_PODKOP, current)
        -- Deliberately different parameters must not turn reinstall into enable's UCI save.
        assert.same({ success = true, installed = true }, SBX.wrapper_toggle("reinstall", nil, "1", "20ms"))
        assert.is_true(called)
        assert.equal(original, H.vfs_read(ORIG))
        assert.equal(current, H.vfs_read(INIT_PODKOP))
        assert.equal(SB_OK, H.vfs_read(CFG))
        assert.same(saved_uci, H.state().uci)
        assert_no_lua_mutation()
        assert_checked_call("enable")
    end)

    it("non-zero exit -> trimmed error message", function()
        local SBX = begin_sbx({ popen = { exit_responder(" \nwrapper failed badly\n \nPT_EXIT:1\n") } })
        local r = SBX.wrapper_toggle("enable", nil, nil, nil)
        assert.is_false(r.success)
        assert.equal("wrapper failed badly", r.error)
        assert.equal(" \nwrapper failed badly\n ", r.details)
        assert.is_true(r.settings_saved)
        assert_checked_call("enable")
    end)

    it("failed reinstall preserves the original and the complete multiline diagnostics", function()
        local original = wrapper_init(1, 0)
        local diagnostics = "normalization refused\nPT_EXIT:0\n" ..
            string.rep("  validation context: retain the original and current init\n", 256) .. "no files published"
        local saved_uci = { ["podkop-fragment"] = { H.sec("settings", "fragment", { enabled = "0", fragment = "true" }) } }
        local SBX = begin_sbx({ uci = H.json.parse(H.json.stringify(saved_uci)), popen = { exit_responder(function()
            assert.equal(original, H.vfs_read(ORIG))
            assert_no_lua_mutation()
            return diagnostics .. "\nPT_EXIT:23\n"
        end) } })
        H.vfs_write(ORIG, original)
        H.vfs_write(INIT_PODKOP, wrapper_init(3, 3))
        local r = SBX.wrapper_toggle("reinstall", "1", "1", "1ms")
        assert.is_false(r.success)
        assert.equal(diagnostics, r.error)
        assert.equal(diagnostics, r.details)
        assert.is_nil(r.settings_saved)
        assert.equal(original, H.vfs_read(ORIG))
        assert.equal(wrapper_init(3, 3), H.vfs_read(INIT_PODKOP))
        assert.same(saved_uci, H.state().uci)
        assert_no_lua_mutation()
        assert_checked_call("enable")
    end)

    it("missing PT_EXIT marker -> treated as failure", function()
        local SBX = begin_sbx({ popen = { exit_responder("weird output\n") } })
        local r = SBX.wrapper_toggle("disable", nil, nil, nil)
        assert.is_false(r.success)
        assert.is_true(r.unknown)
        assert.equal("weird output\n", r.details:sub(1, #"weird output\n"))
        assert.truthy(r.details:find("Missing or invalid final PT_EXIT marker", 1, true))
        assert.equal(r.details:match("^%s*(.-)%s*$"), r.error)
        assert_checked_call("disable")
    end)

    for _, case in ipairs({
        { name = "legacy EXIT success", output = "EXIT:0\n" },
        { name = "unterminated PT_EXIT success", output = "result\nPT_EXIT:0" },
        { name = "non-final PT_EXIT success", output = "\nPT_EXIT:0\nstill running\n" }
    }) do
        it("does not accept " .. case.name .. " as a checked result", function()
            local SBX = begin_sbx({ popen = { exit_responder(case.output) } })
            local r = SBX.wrapper_toggle("disable", nil, nil, nil)
            assert.is_false(r.success)
            assert.is_true(r.unknown)
            assert.equal(case.output, r.details:sub(1, #case.output), "retain all raw output before the unknown-result diagnostic")
            assert.truthy(r.details:find("Missing or invalid final PT_EXIT marker", 1, true))
            assert.equal(r.details:match("^%s*(.-)%s*$"), r.error)
            assert_checked_call("disable")
        end)
    end

    for _, case in ipairs({
        { name = "open failure", pipe = { open_error = "pipe creation failed", open_errno = 24 }, detail = "pipe creation failed", acquired = false },
        { name = "interrupted read", pipe = { read_error = "Interrupted system call", read_errno = 4 }, detail = "Interrupted system call", acquired = true },
        { name = "partial interrupted read", pipe = { read_error = "Interrupted system call", read_errno = 4,
            read_output = "wrapper published\nPT_EXIT:0\n" }, detail = "wrapper published\nPT_EXIT:0\n", acquired = true },
        { name = "close failure after successful marker", pipe = { content = "wrapper published\nPT_EXIT:0\n",
            close_error = "close failed", close_errno = 5 }, detail = "close failed", acquired = true }
    }) do
        it("keeps UCI/original and reports unknown after " .. case.name .. " without replay", function()
            local original, current = wrapper_init(0, 0), wrapper_init(1, 1, LEGACY_HOOK)
            local saved_uci = { ["podkop-fragment"] = { H.sec("settings", "fragment", {
                enabled = "0", singbox_config = "/etc/sing-box/custom.json", unknown = "keep" }) } }
            local SBX = begin_sbx({ uci = H.json.parse(H.json.stringify(saved_uci)), popen = { exit_responder(case.pipe) } })
            H.vfs_write(ORIG, original)
            H.vfs_write(INIT_PODKOP, current)
            local r = SBX.wrapper_toggle("reinstall", "1", "1", "1ms")
            assert.is_false(r.success)
            assert.is_true(r.unknown)
            assert.is_nil(r.installed)
            assert.is_nil(r.settings_saved)
            assert.truthy(r.details:find(case.detail, 1, true))
            assert.equal(original, H.vfs_read(ORIG))
            assert.equal(current, H.vfs_read(INIT_PODKOP))
            assert.same(saved_uci, H.state().uci)
            assert_no_lua_mutation()
            assert_checked_call("enable")
            local pipes = H.state().pipe_log
            assert.equal(1, #pipes)
            assert.equal(case.acquired, pipes[1].acquired)
            assert.same(case.acquired and { "*a" } or {}, pipes[1].reads)
            assert.equal(case.acquired and 1 or 0, pipes[1].close_calls)
        end)
    end

    it("does not replay a reinstall whose shell publication completed before an interrupted response read", function()
        local original = wrapper_init(0, 0)
        local saved_uci = { ["podkop-fragment"] = { H.sec("settings", "fragment", { enabled = "0", unknown = "keep" }) } }
        local SBX = begin_sbx({ uci = H.json.parse(H.json.stringify(saved_uci)), popen = { exit_responder(function()
            H.vfs_write(ORIG, original)
            H.vfs_write(INIT_PODKOP, wrapper_init(1, 1))
            return { read_error = "Interrupted system call", read_errno = 4 }
        end) } })
        H.vfs_write(ORIG, wrapper_init(1, 0, LEGACY_HOOK))
        H.vfs_write(INIT_PODKOP, wrapper_init({ LEGACY_HOOK, OWNED_HOOK }, { LEGACY_HOOK }))
        local r = SBX.wrapper_toggle("reinstall")
        assert.is_false(r.success)
        assert.is_true(r.unknown)
        assert.is_nil(r.installed, "an interrupted response cannot confirm shell state")
        assert.is_nil(r.applied, "transport failure cannot infer a completed mutation")
        assert.truthy(r.details:find("errno=4", 1, true))
        assert.equal(original, H.vfs_read(ORIG))
        assert.equal(wrapper_init(1, 1), H.vfs_read(INIT_PODKOP))
        assert.same(saved_uci, H.state().uci)
        assert_no_lua_mutation()
        assert_checked_call("enable")
        -- A separate explicit status GET can inspect the published bytes without
        -- issuing another mutation or changing the complete disabled-master UCI.
        assert.same({ installed = true, stale = false }, SBX.wrapper_status())
        assert_checked_call("enable")
    end)

    for _, operation in ipairs({ "set", "commit" }) do
        it("does not invoke the wrapper after a failed UCI " .. operation, function()
            local original = wrapper_init(1, 0)
            local SBX = begin_sbx({
                uci = { ["podkop-fragment"] = { H.sec("settings", "fragment", { enabled = "0", unknown = "keep" }) } },
                uci_failures = { ["podkop-fragment"] = { [operation] = true } }
            })
            H.vfs_write(ORIG, original)
            local r = SBX.wrapper_toggle("enable", "1", "1", "700ms")
            assert.is_false(r.success)
            assert.truthy(r.error)
            assert.truthy(r.details)
            assert.is_nil(r.installed)
            assert.equal(0, #commands_containing("/etc/init.d/podkop-fragment"))
            assert.equal(original, H.vfs_read(ORIG))
            H.state().uci_failures["podkop-fragment"] = {}
            local uci = require("luci.model.uci").cursor()
            assert.equal("0", uci:get("podkop-fragment", "settings", "enabled"))
            assert.equal("keep", uci:get("podkop-fragment", "settings", "unknown"))
        end)
    end

    it("does not run the wrapper after a thrown UCI field-save error", function()
        local SBX = begin_sbx({ uci = { ["podkop-fragment"] = { H.sec("settings", "fragment", { enabled = "0" }) } } })
        local uci = require("luci.model.uci").cursor()
        local set = uci.set
        uci.set = function(self, conf, section, option, value)
            if option == "record_fragment" then error("native UCI save failed") end
            return set(self, conf, section, option, value)
        end
        local r = SBX.wrapper_toggle("enable", "1", "1", "700ms")
        assert.is_false(r.success)
        assert.equal("Cannot save Fragment setting: record_fragment", r.error)
        assert.truthy(r.details:find("native UCI save failed", 1, true))
        assert.equal(0, #H.commits())
        assert.equal(0, #commands_containing("/etc/init.d/podkop-fragment"))
    end)

    it("reports quiet nonzero wrapper exits and post-command state read failures explicitly", function()
        local SBX = begin_sbx({ popen = { exit_responder("\nPT_EXIT:1\n") } })
        local failed = SBX.wrapper_toggle("disable")
        assert.is_false(failed.success)
        assert.equal("Wrapper command failed", failed.error)
        H.finish()
        SBX = begin_sbx({ popen = { exit_responder("\nPT_EXIT:0\n") }, failures = { [ORIG] = { close = true } } })
        H.vfs_write(ORIG, "original")
        local unknown = SBX.wrapper_toggle("reinstall")
        assert.is_false(unknown.success)
        assert.equal("Cannot read wrapper state", unknown.error)
        assert.is_nil(unknown.installed)
        assert.equal("original", H.vfs_read(ORIG))
    end)

    it("does not confirm an enable command whose observed wrapper state is still absent", function()
        local SBX = begin_sbx({ popen = { exit_responder("\nPT_EXIT:0\n") } })
        local r = SBX.wrapper_toggle("enable", nil, "1", "500ms")
        assert.is_false(r.success)
        assert.is_false(r.installed)
        assert.is_true(r.settings_saved)
        assert.equal("Wrapper state did not change as requested", r.error)
    end)

    it("creates the native fragment section on first use", function()
        local SBX = begin_sbx({ popen = { exit_responder("\nPT_EXIT:0\n") } })
        H.vfs_write(ORIG, "original")
        local uci = fragment_rpc_reply(nil, "An absent first-use file must not need an RPC read")
        uci.get_all = function() error("unexpected RPC for absent config") end
        assert.is_true(SBX.wrapper_toggle("enable", "1", "0", "700ms").success)
        assert.equal("fragment", uci:get("podkop-fragment", "settings"))
        assert.equal("true", uci:get("podkop-fragment", "settings", "fragment"))
        assert.equal("700ms", uci:get("podkop-fragment", "settings", "fragment_fallback_delay"))
        assert_checked_call("enable")
    end)

    it("does not recreate an existing native section and preserves its master/unknown values", function()
        local section = H.sec("settings", "fragment", { enabled = "0", fragment = "false", record_fragment = "true",
            fragment_fallback_delay = "500ms", unknown = "keep", custom_list = { "first", "second" } })
        local SBX = begin_sbx({ popen = { exit_responder("\nPT_EXIT:0\n") }, uci = { ["podkop-fragment"] = { section } } })
        H.vfs_write(FRAGMENT_CONFIG, FRAGMENT_RAW)
        H.vfs_write(ORIG, "original")
        local uci = fragment_rpc_reply({ settings = section })
        local set = uci.set
        uci.set = function(self, config, name, option, value)
            assert.is_not_nil(value, "an existing section must not be recreated")
            return set(self, config, name, option, value)
        end
        assert.is_true(SBX.wrapper_toggle("enable", "1", "0", "700ms").success)
        assert.equal("fragment", uci:get("podkop-fragment", "settings"))
        assert.equal("0", uci:get("podkop-fragment", "settings", "enabled"))
        assert.equal("keep", uci:get("podkop-fragment", "settings", "unknown"))
        assert.same({ "first", "second" }, uci:get("podkop-fragment", "settings", "custom_list"))
        assert_checked_call("enable")
    end)

    it("blocks Enable on a failed whole-package UCI read instead of creating default settings", function()
        local SBX = begin_sbx()
        H.vfs_write(FRAGMENT_CONFIG, FRAGMENT_RAW)
        H.vfs_write(ORIG, "original")
        local details = string.rep("native UCI parse failure\n", 100)
        local uci = fragment_rpc_reply(nil, details)
        uci.set = function() error("must not save after a failed config read") end
        local r = SBX.wrapper_toggle("enable", "1", "0", "700ms")
        assert.is_false(r.success)
        assert.equal("Cannot read Fragment settings", r.error)
        assert.equal(details, r.details)
        assert.same({}, H.commits())
        assert.equal(0, #commands_containing("/etc/init.d/podkop-fragment"))
        assert.equal(FRAGMENT_RAW, H.vfs_read(FRAGMENT_CONFIG))
        assert.equal("original", H.vfs_read(ORIG))
    end)
end)

describe("api_singbox.fragment_settings", function()
    local function assert_read_only()
        assert.same({}, H.commits())
        assert.equal(0, #H.exec_cmds())
        assert.equal(0, #H.popen_cmds())
        for _, call in ipairs(H.state().io_log) do
            assert.not_equal("write", call.operation)
            assert.not_equal("rename", call.operation)
            assert.not_equal("remove", call.operation)
        end
    end

    local function assert_read_error(result)
        assert.is_false(result.success)
        assert.truthy(result.error)
        assert.is_nil(result.fragment)
        assert.is_nil(result.record_fragment)
        assert.is_nil(result.fallback_delay)
        assert.is_nil(result.settings_source)
        assert_read_only()
    end

    it("returns explicit typed first-use defaults only for ENOENT without a native RPC", function()
        local SBX = begin_sbx()
        local uci = fragment_rpc_reply(nil, "must not be used for first use")
        uci.get_all = function() error("must not query an absent first-use package") end
        assert.same({ fragment = false, record_fragment = true, fallback_delay = "500ms",
            settings_source = "defaults", config_missing = true }, SBX.fragment_settings())
        assert.is_nil(H.vfs_read(FRAGMENT_CONFIG))
        assert_read_only()
    end)

    it("maps current native string values to the frontend boolean/string schema", function()
        local SBX = begin_sbx()
        H.vfs_write(FRAGMENT_CONFIG, FRAGMENT_RAW)
        local uci = fragment_rpc_reply({ settings = H.sec("settings", "fragment", {
            fragment = "true", record_fragment = "false", fragment_fallback_delay = "300ms", enabled = "0", unknown = "keep" }) })
        uci.get = function() error("per-option get cannot establish native parse success") end
        assert.same({ fragment = true, record_fragment = false, fallback_delay = "300ms",
            settings_source = "uci", config_missing = false }, SBX.fragment_settings())
        assert.equal(FRAGMENT_RAW, H.vfs_read(FRAGMENT_CONFIG))
        assert_read_only()
    end)

    it("permits missing section/fields only after a successful whole-package native parse", function()
        local SBX = begin_sbx()
        H.vfs_write(FRAGMENT_CONFIG, "config custom 'extra'\n\toption value 'keep'\n")
        fragment_rpc_reply({ extra = H.sec("extra", "custom", { value = "keep" }) })
        assert.same({ fragment = false, record_fragment = true, fallback_delay = "500ms",
            settings_source = "defaults", config_missing = false }, SBX.fragment_settings())
        H.vfs_write(FRAGMENT_CONFIG, "config fragment 'settings'\n")
        fragment_rpc_reply({ settings = H.sec("settings", "fragment", {}) })
        assert.same({ fragment = false, record_fragment = true, fallback_delay = "500ms",
            settings_source = "uci", config_missing = false }, SBX.fragment_settings())
        assert_read_only()
    end)

    for _, operation in ipairs({ "open", "read", "close" }) do
        it("does not convert an existing configuration " .. operation .. " error into defaults", function()
            local SBX = begin_sbx({ failures = { [FRAGMENT_CONFIG] = { [operation] = true, errno = 13 } } })
            H.vfs_write(FRAGMENT_CONFIG, FRAGMENT_RAW)
            local uci = fragment_rpc_reply({})
            uci.get_all = function() error("must not query after a failed bounded read") end
            local r = SBX.fragment_settings()
            assert_read_error(r)
            assert.equal("Cannot read Fragment settings", r.error)
            assert.truthy(r.details:find("Injected " .. operation .. " failure", 1, true))
            assert.equal(FRAGMENT_RAW, H.vfs_read(FRAGMENT_CONFIG))
        end)
    end

    for _, raw in ipairs({ "", " \n\t", string.rep("x", 1048577) }) do
        it("rejects an empty/whitespace/oversize existing file before native parsing (bytes " .. #raw .. ")", function()
            local SBX = begin_sbx()
            H.vfs_write(FRAGMENT_CONFIG, raw)
            local uci = fragment_rpc_reply({})
            uci.get_all = function() error("must not query invalid bounded input") end
            assert_read_error(SBX.fragment_settings())
            assert.equal(raw, H.vfs_read(FRAGMENT_CONFIG))
        end)
    end

    it("retains whole-package RPC/parse diagnostics and catches native read exceptions", function()
        local SBX = begin_sbx()
        H.vfs_write(FRAGMENT_CONFIG, FRAGMENT_RAW)
        local details = string.rep("native UCI read error\n", 100)
        local uci = fragment_rpc_reply(nil, details)
        local r = SBX.fragment_settings()
        assert_read_error(r)
        assert.equal(details, r.details)
        uci.get_all = function() error(details, 0) end
        local thrown = SBX.fragment_settings()
        assert_read_error(thrown)
        assert.equal(details, thrown.details)
    end)

    for _, native in ipairs({ false, "not a package", { error = "RPC error object" },
        { settings = {} }, { settings = H.sec("other", "fragment", {}) },
        { settings = H.sec("settings", "unexpected", {}) } }) do
        it("does not normalize a malformed native package/section response", function()
            local SBX = begin_sbx()
            H.vfs_write(FRAGMENT_CONFIG, FRAGMENT_RAW)
            fragment_rpc_reply(native)
            assert_read_error(SBX.fragment_settings())
        end)
    end

    for _, case in ipairs({
        { field = "fragment", value = false }, { field = "fragment", value = "1" },
        { field = "record_fragment", value = {} }, { field = "record_fragment", value = "TRUE" },
        { field = "fragment_fallback_delay", value = 500 }, { field = "fragment_fallback_delay", value = "" },
        { field = "fragment_fallback_delay", value = "500 ms" }, { field = "fragment_fallback_delay", value = {} }
    }) do
        it("rejects an invalid stored field instead of supplying a typed default: " .. case.field .. "/" .. type(case.value), function()
            local SBX = begin_sbx()
            H.vfs_write(FRAGMENT_CONFIG, FRAGMENT_RAW)
            local values = { fragment = "true", record_fragment = "false", fragment_fallback_delay = "300ms" }
            values[case.field] = case.value
            fragment_rpc_reply({ settings = H.sec("settings", "fragment", values) })
            local r = SBX.fragment_settings()
            assert_read_error(r)
            assert.equal("Invalid Fragment setting: " .. case.field, r.error)
        end)
    end
end)
