-- pt_auto_update_spec | v1.0.0 | 23.08.2026 | Coverage for standalone pt-auto-update.lua (executes at require, cron/hotplug entry)

package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path

local H = require("pt_harness")

local SUBS = "/etc/config/podkop-tweaker-subs.json"
local LOG = "/etc/config/pt-update.log"
local CFG = "/etc/config/podkop"

local LINK_OLD = "vless://old@srv:443?security=tls#OldName"
local CFG_TEXT = "config section 'main'\n\toption connection_type 'proxy'\n\toption proxy_config_type 'url'\n\toption proxy_string '" .. LINK_OLD .. "'\n"
local UCI_MAIN = { podkop = { H.sec("main", "section", {
    connection_type = "proxy", proxy_config_type = "url", proxy_string = LINK_OLD }) } }
local SUB_ENTRY = '{"main":[{"subscription_url":"https://sub/1","proxy_name":"OldName"}]}'

local function run_auto(opts)
    opts = opts or {}
    local network, checked = opts.popen, opts.sys or {}
    checked[#checked + 1] = { match = "pidof 'sing-box'", out = "\nPT_EXIT:1\n" }
    checked[#checked + 1] = { match = "/etc/init.d/podkop restart", out = "\nPT_EXIT:0\n" }
    opts.sys = checked
    opts.popen = function(command)
        for _, responder in ipairs(checked) do
            if command:find(responder.match, 1, true) then
                return type(responder.out) == "function" and responder.out(command) or responder.out
            end
        end
        if type(network) == "function" then return network(command) end
        for _, responder in ipairs(network or {}) do
            if command:find(responder.match, 1, true) then
                return type(responder.out) == "function" and responder.out(command) or responder.out
            end
        end
        return nil
    end
    H.begin(opts)
    local sequence = 0
    require("pt-subs-lib").new_operation_id = function() sequence = sequence + 1; return string.format("%032x", sequence) end
end

local function restart_count()
    local n = 0
    for _, c in ipairs(H.popen_cmds()) do
        if c:find("/etc/init.d/podkop restart", 1, true) then n = n + 1 end
    end
    return n
end

after_each(function()
    H.finish()
end)

describe("pt-auto-update", function()
    it("updated subscription: rewrites config, restarts podkop, logs auto mode", function()
        run_auto({
            uci = UCI_MAIN,
            popen = function(cmd)
                if cmd:find("curl", 1, true) then return (H.vfs_read("/tmp/pt-fixed") or "") .. "\nPT_CURL_EXIT:0\n" end
                return nil
            end
        })
        H.vfs_write(CFG, CFG_TEXT)
        H.vfs_write(SUBS, SUB_ENTRY)
        H.vfs_write("/tmp/pt-fixed", "vless://fresh@f:443#OldName\n")
        package.loaded["pt-auto-update"] = nil
        local result = require("pt-auto-update")

        assert.is_true(result.success)
        assert.is_true(result.verification_required)
        assert.truthy(H.vfs_read(CFG):find("vless://fresh@f:443#OldName", 1, true))
        assert.equal(1, restart_count())
        local log = H.vfs_read(LOG)
        assert.truthy(log:find("|auto|", 1, true))
        assert.truthy(log:find("updated=1", 1, true))
        assert.truthy(log:find("OldName: updated", 1, true))
    end)

    it("unchanged subscription: no restart", function()
        run_auto({
            uci = UCI_MAIN,
            popen = function(cmd)
                if cmd:find("curl", 1, true) then return (H.vfs_read("/tmp/pt-fixed") or "") .. "\nPT_CURL_EXIT:0\n" end
                return nil
            end
        })
        H.vfs_write(CFG, CFG_TEXT)
        H.vfs_write(SUBS, SUB_ENTRY)
        H.vfs_write("/tmp/pt-fixed", LINK_OLD .. "\n")
        package.loaded["pt-auto-update"] = nil
        require("pt-auto-update")

        assert.equal(CFG_TEXT, H.vfs_read(CFG))
        assert.equal(0, restart_count())
        assert.truthy(H.vfs_read(LOG):find("unchanged=1", 1, true))
    end)

    it("failed download: retries logged, no restart", function()
        run_auto({
            uci = UCI_MAIN,
            popen = function(cmd)
                if cmd:find("curl", 1, true) then return (H.vfs_read("/tmp/pt-fixed") or "") .. "\nPT_CURL_EXIT:0\n" end
                return nil
            end
        })
        H.vfs_write(CFG, CFG_TEXT)
        H.vfs_write(SUBS, SUB_ENTRY)
        H.vfs_write("/tmp/pt-fixed", "garbage\n")
        package.loaded["pt-auto-update"] = nil
        require("pt-auto-update")

        assert.equal(CFG_TEXT, H.vfs_read(CFG))
        assert.equal(0, restart_count())
        local log = H.vfs_read(LOG)
        assert.truthy(log:find("failed=1", 1, true))
        local sleeps = 0
        for _, c in ipairs(H.execute_cmds()) do
            if c:find("^sleep 10") then sleeps = sleeps + 1 end
        end
        assert.equal(2, sleeps)
    end)

    it("empty world: zero counters and a completed log without config/service mutation", function()
        run_auto({})
        require("pt-auto-update")
        assert.equal(0, restart_count())
        local log = H.vfs_read(LOG)
        assert.truthy(log)
        assert.truthy(log:find("updated=0|unchanged=0|failed=0", 1, true))
    end)

    for _, failure in ipairs({
        { name = "empty", bytes = "" }, { name = "malformed", bytes = "broken state" },
        { name = "wrong type", bytes = "[]" }, { name = "open", rule = { open = true, errno = 5 } },
        { name = "read", rule = { read = true } }, { name = "close", rule = { close = true } }
    }) do
        it("fails the standalone invocation on " .. failure.name .. " state instead of logging zero updates", function()
            run_auto({ uci = UCI_MAIN, failures = failure.rule and { [SUBS] = failure.rule } or {} })
            local bytes = failure.bytes or SUB_ENTRY
            H.vfs_write(SUBS, bytes)
            H.vfs_write(CFG, CFG_TEXT)
            H.vfs_write(LOG, "previous journal\n")
            local ok, err = pcall(require, "pt-auto-update")
            assert.is_false(ok)
            assert.is_string(err)
            assert.equal(bytes, H.vfs_read(SUBS))
            assert.equal(CFG_TEXT, H.vfs_read(CFG))
            assert.equal("previous journal\n", H.vfs_read(LOG))
            assert.equal(0, restart_count())
            assert.same({}, H.stage_paths())
            for _, command in ipairs(H.popen_cmds()) do assert.falsy(command:find("curl", 1, true)) end
        end)
    end

    it("fails on a final state-write failure and leaves a prepublication config untouched", function()
        run_auto({ uci = UCI_MAIN, failures = { [SUBS .. ".tmp.*"] = { write = true, partial = 4 } },
            popen = function(cmd)
                if cmd:find("curl", 1, true) then return "vless://fresh@f:443#OldName\nPT_CURL_EXIT:0\n" end
                return nil
            end })
        H.vfs_write(SUBS, SUB_ENTRY)
        H.vfs_write(CFG, CFG_TEXT)
        H.vfs_write(LOG, "previous journal\n")
        local ok, err = pcall(require, "pt-auto-update")
        assert.is_false(ok)
        assert.matches("write", err)
        assert.equal(SUB_ENTRY, H.vfs_read(SUBS))
        assert.equal(CFG_TEXT, H.vfs_read(CFG))
        assert.matches("^previous journal\n", H.vfs_read(LOG))
        assert.matches("|state=finished|service=not_required|skipped=0|outcome=failed", H.vfs_read(LOG), 1, true)
        assert.equal(0, restart_count())
    end)

    it("exposes a journal failure instead of returning a successful standalone result", function()
        run_auto({ uci = UCI_MAIN, failures = { [LOG] = { rename = true } },
            popen = function(cmd)
                if cmd:find("curl", 1, true) then return LINK_OLD .. "\nPT_CURL_EXIT:0\n" end
                return nil
            end })
        H.vfs_write(SUBS, SUB_ENTRY)
        H.vfs_write(CFG, CFG_TEXT)
        H.vfs_write(LOG, "previous journal\n")
        local ok, err = pcall(require, "pt-auto-update")
        assert.is_false(ok)
        assert.matches("log", err)
        assert.equal("previous journal\n", H.vfs_read(LOG))
        assert.equal(0, restart_count())
    end)

    it("does not resurrect a manual Detach or log Save performed by another actor during the download", function()
        local fetched = 0
        run_auto({ uci = UCI_MAIN, popen = function(cmd)
            if not cmd:find("curl", 1, true) then return nil end
            fetched = fetched + 1
            local actor = coroutine.create(function()
                local api = require("podkop-tweaker.api_subs")
                assert.is_true(api.subscription_detach("main", "0").success)
                assert.is_true(api.settings_save(nil, nil, nil, "22", true).success)
            end)
            local ok, err = coroutine.resume(actor)
            assert.is_true(ok, tostring(err))
            assert.equal("dead", coroutine.status(actor))
            return "vless://fresh@f:443#OldName\nPT_CURL_EXIT:0\n"
        end })
        H.vfs_write(CFG, CFG_TEXT)
        H.vfs_write(SUBS, SUB_ENTRY)
        local result = require("pt-auto-update")
        assert.is_true(result.success)
        assert.equal(1, result.skipped)
        assert.equal(0, result.updated)
        assert.equal(1, fetched)
        local state = require("pt-subs-lib").read_subs(SUBS)
        assert.is_nil(state.main[1])
        assert.equal(22, state.settings.log_display_count)
        assert.equal(CFG_TEXT, H.vfs_read(CFG))
        assert.equal(0, restart_count())
    end)

    it("reports a checked restart failure and preserves the failure if journaling also fails", function()
        run_auto({ uci = UCI_MAIN, sys = { { match = "/etc/init.d/podkop restart", out = function()
            H.state().failures[LOG] = { rename = true }
            return "restart denied\nPT_EXIT:1\n"
        end } }, popen = function(cmd)
            if cmd:find("curl", 1, true) then return "vless://fresh@f:443#OldName\nPT_CURL_EXIT:0\n" end
            return nil
        end })
        H.vfs_write(CFG, CFG_TEXT)
        H.vfs_write(SUBS, SUB_ENTRY)
        local ok, err = pcall(require, "pt-auto-update")
        assert.is_false(ok)
        assert.matches("restart denied", err)
        assert.matches("Cannot finalize subscription update log", err)
        assert.truthy(H.vfs_read(CFG):find("vless://fresh@f:443#OldName", 1, true))
        assert.equal(1, restart_count())
        assert.equal(1, #H.stage_paths(CFG .. ".tmp.*"))
    end)

    for _, capture in ipairs({
        { name = "EINTR read", output = { read_error = "Interrupted system call", read_errno = 4 },
            diagnostic = "read failed: Interrupted system call (errno=4)" },
        { name = "close error", output = { content = "\nPT_EXIT:0\n", close_error = "Close failed", close_errno = 5 },
            diagnostic = "close failed: Close failed (errno=5)" },
        { name = "missing marker", output = "incomplete restart capture",
            diagnostic = "marker failed: Missing or invalid final PT_EXIT marker" }
    }) do
        it("reports " .. capture.name .. " uncertainty without inventing a lock-release failure", function()
            run_auto({ strict = true, uci = UCI_MAIN,
                sys = { { match = "/etc/init.d/podkop restart", out = capture.output } },
                popen = { { match = "curl ", out = "vless://fresh@f:443#OldName\nPT_CURL_EXIT:0\n" } } })
            H.vfs_write(CFG, CFG_TEXT)
            H.vfs_write(SUBS, SUB_ENTRY)
            local s = require("pt-subs-lib")
            local finish, observed = s.finish_subscription_update, nil
            s.finish_subscription_update = function(result)
                observed = finish(result)
                return observed
            end
            local ok, err = pcall(require, "pt-auto-update")
            assert.is_false(ok)
            assert.matches("Service restart outcome is unknown", err, 1, true)
            assert.matches(capture.diagnostic, err, 1, true)
            assert.falsy(err:lower():find("lock release", 1, true))
            assert.falsy(err:find("cannot release owned lock", 1, true))
            assert.is_true(observed.unknown)
            assert.is_true(observed.applied)
            assert.equal("unknown", observed.service)
            assert.equal("partial", observed.outcome)
            assert.equal(1, observed.updated)
            assert.equal(0, observed.unchanged)
            assert.equal(0, observed.failed)
            assert.is_false(observed.restart.command_result_known)
            assert.is_nil(observed.restart.command_exit_code)
            assert.matches(capture.diagnostic, observed.restart.details, 1, true)
            assert.same({ recorded = true, finalized = true }, observed.journal)
            local count, event = 0, nil
            for line in H.vfs_read(LOG):gmatch("[^\n]+") do
                local parsed = s.parse_log_header(line)
                if parsed then count, event = count + 1, parsed end
            end
            assert.equal(1, count)
            assert.equal(observed.operation_id, event.id)
            assert.equal("finished", event.state)
            assert.equal("unknown", event.service)
            assert.equal(1, event.updated)
            assert.equal(0, event.unchanged)
            assert.equal(0, event.failed, "capture loss cannot become a slot failure")
            assert.equal(1, restart_count())
            for _, lock in ipairs({ "/var/lock/podkop-tweaker-subscriptions.lock", "/var/lock/podkop-tweaker-podkop.lock" }) do
                assert.falsy(H.vfs_exists(lock))
                local released = false
                for _, call in ipairs(H.state().io_log) do
                    if call.operation == "rmdir" and call.path == lock then
                        assert.is_true(call.success)
                        released = true
                    end
                end
                assert.is_true(released, "the fixture must confirm the actual lock releases")
            end
        end)
    end

    it("does not claim on-disk changes after a failed snapshot read and release", function()
        run_auto({ strict = true, uci = UCI_MAIN, failures = {
            [SUBS] = { read = true }, ["/var/lock/podkop-tweaker-subscriptions.lock"] = { rmdir = true }
        } })
        H.vfs_write(SUBS, SUB_ENTRY)
        H.vfs_write(CFG, CFG_TEXT)
        H.vfs_write(LOG, "previous journal\n")
        local ok, err = pcall(require, "pt-auto-update")
        assert.is_false(ok)
        assert.matches("Cannot read subscriptions", err)
        assert.matches("cannot release owned lock", err)
        assert.falsy(err:find("changes are already on disk", 1, true))
        assert.equal(SUB_ENTRY, H.vfs_read(SUBS))
        assert.equal(CFG_TEXT, H.vfs_read(CFG))
        assert.equal("previous journal\n", H.vfs_read(LOG))
        assert.same({}, H.stage_paths())
        assert.equal(0, restart_count())
    end)

    it("fails after actual config publication and final state-write failure without replay or restart", function()
        local fetches = 0
        run_auto({ strict = true, uci = UCI_MAIN, failures = { [SUBS] = { rename = true } },
            popen = { { match = "curl ", out = function()
                fetches = fetches + 1
                return "vless://fresh@f:443#OldName\nPT_CURL_EXIT:0\n"
            end } } })
        H.vfs_write(CFG, CFG_TEXT)
        H.vfs_write(SUBS, SUB_ENTRY)
        H.vfs_write(LOG, "previous journal\n")
        local ok, err = pcall(require, "pt-auto-update")
        assert.is_false(ok)
        assert.matches("Cannot save subscription state", err)
        assert.truthy(err:find("Subscription changes are already on disk.", 1, true))
        assert.truthy(err:find("Podkop restart remains required.", 1, true))
        assert.equal(SUB_ENTRY, H.vfs_read(SUBS))
        assert.truthy(H.vfs_read(CFG):find("vless://fresh@f:443#OldName", 1, true))
        assert.matches("^previous journal\n", H.vfs_read(LOG))
        assert.matches("|state=finished|service=pending|skipped=0|outcome=partial", H.vfs_read(LOG), 1, true)
        assert.equal(1, fetches)
        assert.equal(0, restart_count())
        assert.equal(1, #H.stage_paths(CFG .. ".tmp.*"))
    end)

    for _, requested in ipairs({ false, true }) do
        it("preserves the standalone restart outcome if release fails (requested=" .. tostring(requested) .. ")", function()
            run_auto({ strict = true, uci = UCI_MAIN, sys = {
                { match = "pidof ", out = "\nPT_EXIT:1\n" },
                { match = "/etc/init.d/podkop restart", out = function()
                    H.state().failures["/var/lock/podkop-tweaker-podkop.lock"] = { rmdir = true }
                    return requested and "\nPT_EXIT:0\n" or "primary restart diagnostics\nPT_EXIT:7\n"
                end }
            }, popen = { { match = "curl ", out = "vless://fresh@f:443#OldName\nPT_CURL_EXIT:0\n" } } })
            H.vfs_write(CFG, CFG_TEXT)
            H.vfs_write(SUBS, SUB_ENTRY)
            local ok, err = pcall(require, "pt-auto-update")
            assert.is_false(ok)
            assert.matches("cannot release owned lock", err)
            assert.truthy(err:find("Subscription changes are already on disk.", 1, true))
            if requested then assert.matches("Podkop restart requested", err)
            else assert.matches("primary restart diagnostics", err) end
            assert.truthy(H.vfs_read(CFG):find("vless://fresh@f:443#OldName", 1, true))
            assert.equal(1, restart_count())
            assert.equal(1, #H.stage_paths(CFG .. ".tmp.*"))
        end)
    end
end)
