package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path
local H = require("pt_harness")
local ROOT_CRON = "/etc/crontabs/root"
local CRON_INPUT = "/tmp/pt-subscriptions.cron"
local CRON_STAGES = CRON_INPUT .. ".tmp-write.*"
local LOCK = "/var/lock/podkop-tweaker-subscriptions.lock"
local LAUNCHER = "/usr/bin/pt-auto-update"
local HOTPLUG = "/etc/hotplug.d/iface/99-pt-subs"
after_each(function() H.finish() end)
local function begin(opts)
    opts = opts or {}
    opts.strict = true
    opts.sys = opts.sys or {}
    opts.sys[#opts.sys + 1] = { match = "crontab ", out = function(command)
        local path = command:match("crontab '([^']+)'")
        assert.is_string(path)
        assert.is_not.equal(CRON_INPUT, path)
        assert.equal("600", H.vfs_mode(path))
        local content = H.vfs_read(path)
        assert.is_string(content)
        H.vfs_write(ROOT_CRON, content)
        return "\nPT_EXIT:0\n"
    end }
    opts.sys[#opts.sys + 1] = { match = "(mkdir -p /etc/hotplug.d/iface)", out = "\nPT_EXIT:0\n" }
    opts.popen = opts.sys
    opts.execute = opts.execute or {}
    opts.execute[#opts.execute + 1] = { match = function(command) return command:match("^test %-x ") ~= nil end,
        out = function(command)
            local path = command:match("^test %-x '([^']+)'")
            return H.vfs_mode(path) == "755" and 0 or 1
        end }
    H.begin(opts)
    for path, content in pairs(opts.fs or {}) do H.vfs_write(path, content) end
end

local function no_command(fragment)
    for _, commands in ipairs({ H.exec_cmds(), H.execute_cmds(), H.popen_cmds() }) do
        for _, command in ipairs(commands) do assert.falsy(command:find(fragment, 1, true), command) end
    end
end

local function cleaned_inputs()
    for _, stage in ipairs(H.stage_paths(CRON_STAGES)) do assert.falsy(H.vfs_exists(stage)) end
end

describe("subscription scheduler setup and observation", function()
    it("preserves unrelated crontab entries and replaces only the app job", function()
        local retained = "# keep /usr/bin/pt-auto-update\n\n0 3 * * * /usr/bin/other\r\n" ..
            "15 4 * * * /usr/bin/pt-auto-update-other\n20 4 * * * /bin/echo /usr/bin/pt-auto-update\n"
        begin({ fs = { [ROOT_CRON] = retained .. "0 0 * * * /usr/bin/pt-auto-update\n",
            [CRON_INPUT] = "foreign fixed-path input" } })
        local S = H.reload("podkop-tweaker.subsched")
        assert.is_true(S.setup_cron(4, "01:30"))
        assert.equal(retained .. "30 1,5,9,13,17,21 * * * /usr/bin/pt-auto-update\n", H.vfs_read(ROOT_CRON))
        assert.equal("foreign fixed-path input", H.vfs_read(CRON_INPUT))
        assert.equal(1, #H.stage_paths(CRON_STAGES))
        cleaned_inputs()
        for _, command in ipairs(H.popen_cmds()) do
            if command:find("crontab ", 1, true) then assert.matches("</dev/null", command, 1, true) end
        end
        assert.falsy(H.vfs_exists(LOCK))
    end)

    it("does not replace a crontab that cannot be read or safely staged", function()
        begin({ failures = { [ROOT_CRON] = { open = true } } })
        local S = H.reload("podkop-tweaker.subsched")
        assert.is_false(S.setup_cron(4, "01:30"))
        no_command("crontab ")
        H.finish()
        begin({ failures = { [CRON_STAGES] = { mktemp = true } } })
        S = H.reload("podkop-tweaker.subsched")
        assert.is_false(S.setup_cron(4, "01:30"))
        no_command("crontab ")
        cleaned_inputs()
        assert.falsy(H.vfs_exists(CRON_INPUT))
    end)

    it("distinguishes saved intent, exact installed jobs, executable scripts and auto completions", function()
        begin({ fs = { ["/etc/crontabs/root"] = "30 1,5,9,13,17,21 * * * /usr/bin/pt-auto-update\n",
            ["/etc/config/pt-update.log"] = "08:00 09.10.2026|auto|updated=0|unchanged=2|failed=1\n  detail\n09:00 09.10.2026|manual|updated=1|unchanged=0|failed=0\n" },
            sys = { { match = "pidof crond", out = "123\n" } } })
        local S = H.reload("podkop-tweaker.subsched")
        assert.is_true(S.create_auto_update_script())
        assert.is_true(S.setup_hotplug(true))
        local r = S.status({ auto_update_interval = 4, auto_update_start = "01:30", auto_update_on_restart = true }, "/etc/config/pt-update.log")
        assert.is_true(r.cron.matches)
        assert.is_true(r.cron.running)
        assert.is_true(r.launcher.matches)
        assert.is_true(r.launcher.executable)
        assert.is_true(r.hotplug.matches)
        assert.same({ ts = "08:00 09.10.2026", updated = 0, unchanged = 2, failed = 1, legacy = true }, r.last_auto)
    end)

    it("reports duplicate jobs, altered hooks and non-executable launchers truthfully", function()
        begin({ fs = { ["/etc/crontabs/root"] = "0 0 * * * /usr/bin/pt-auto-update\n0 0 * * * /usr/bin/pt-auto-update\n",
            ["/usr/bin/pt-auto-update"] = "changed", ["/etc/hotplug.d/iface/99-pt-subs"] = "old hook" },
            execute = { { match = "test -x", out = 1 } } })
        local r = H.reload("podkop-tweaker.subsched").status({ auto_update_interval = 24, auto_update_start = "00:00" }, "/missing")
        assert.is_false(r.cron.matches)
        assert.is_false(r.cron.running)
        assert.is_false(r.launcher.matches)
        assert.is_false(r.launcher.executable)
        assert.is_false(r.hotplug.enabled)
        assert.is_true(r.hotplug.exists)
        assert.is_nil(r.last_auto)
    end)

    it("reads a bounded recent journal window and never treats missing history as a successful run", function()
        begin({ fs = { ["/log"] = string.rep("x", 70000) .. "\n12:00 09.10.2026|auto|updated=0|unchanged=0|failed=0\n" } })
        local S = H.reload("podkop-tweaker.subsched")
        local r = S.status({}, "/log")
        assert.equal("12:00 09.10.2026", r.last_auto.ts)
        assert.is_true(r.cron.matches)
        assert.is_false(r.cron.enabled)
        assert.is_nil(S.status({}, "/missing").last_auto)
    end)
    it("can disable triggers without writing a launcher or requiring an absent cron utility", function()
        begin({ execute = { { match = "chmod 755", out = 1 } }, sys = { { match = "crontab ", out = "not found\nPT_EXIT:127\n" } } })
        local S = H.reload("podkop-tweaker.subsched")
        assert.is_true(S.apply(0, "", false))
        assert.falsy(H.vfs_exists("/usr/bin/pt-auto-update"))
        no_command("crontab ")
        assert.same({}, H.stage_paths(CRON_STAGES))
    end)
    it("bundle import reports a scheduler failure after saving subscriptions", function()
        begin({ failures = { [LAUNCHER .. ".tmp-write.*"] = { write = true } } })
        local B = H.reload("podkop-tweaker.bundle")
        local ok, err = B.apply_item("subs", { data = { settings = {
            auto_update_interval = 4, auto_update_start = "01:30", auto_update_on_restart = true
        } } }, { subs_file = "/subs" })
        assert.is_false(ok)
        assert.matches("Subscriptions saved, but scheduling failed", err)
        assert.truthy(H.vfs_exists("/subs"))
        assert.falsy(H.vfs_exists("/usr/bin/pt-auto-update"))
    end)
    it("reports script permission/hotplug failures and preserves an existing hook on failed replacement", function()
        begin({ fs = { ["/etc/hotplug.d/iface/99-pt-subs"] = "old hook" },
            execute = { { match = "chmod 755", out = 1 } } })
        local S = H.reload("podkop-tweaker.subsched")
        assert.is_false(S.setup_hotplug(true))
        assert.equal("old hook", H.vfs_read("/etc/hotplug.d/iface/99-pt-subs"))
        H.finish()
        begin({ failures = { [ROOT_CRON] = { open = true } } })
        local r = H.reload("podkop-tweaker.subsched").status({}, "/missing")
        assert.truthy(r.cron.error)
        assert.is_false(r.cron.matches)
    end)
    it("skips a cut journal header and does not mistake it for a completion", function()
        local header = "12:00 09.10.2026|auto|updated=0|unchanged=0|failed=0"
        begin({ fs = { ["/log"] = "partial-prefix" .. header .. "\n" .. string.rep(" ", 65536 - #header - 1) } })
        assert.is_nil(H.reload("podkop-tweaker.subsched").status({}, "/log").last_auto)
    end)

    it("separates the latest completed auto event from the latest outstanding pending event", function()
        local id_a, id_b = string.rep("a", 32), string.rep("b", 32)
        local completed = "12:00 19.10.2026|auto|updated=1|unchanged=0|failed=0|id=" .. id_a ..
            "|state=finished|service=failed|skipped=2|outcome=partial\n"
        local pending = "12:00 19.10.2026|auto|updated=1|unchanged=0|failed=0|outcome=pending|id=" .. id_b ..
            "|service=pending|state=pending|skipped=0\n"
        begin({ fs = { ["/log"] = "11:00 19.10.2026|auto|updated=0|unchanged=1|failed=0\n" .. completed .. pending } })
        local r = H.reload("podkop-tweaker.subsched").status({}, "/log")
        assert.same({ ts = "12:00 19.10.2026", updated = 1, unchanged = 0, failed = 0, id = id_a,
            state = "finished", service = "failed", skipped = 2, outcome = "partial" }, r.last_auto)
        assert.same({ ts = "12:00 19.10.2026", updated = 1, unchanged = 0, failed = 0, id = id_b,
            state = "pending", service = "pending", skipped = 0, outcome = "pending" }, r.last_auto_pending)
    end)

    for _, terminal in ipairs({
        { name = "legacy", suffix = "" },
        { name = "finished ok", suffix = "|id=" .. string.rep("b", 32) .. "|state=finished|service=requested|skipped=0|outcome=ok" },
        { name = "finished partial", suffix = "|id=" .. string.rep("b", 32) .. "|state=finished|service=failed|skipped=0|outcome=partial" },
        { name = "finished failed", suffix = "|id=" .. string.rep("b", 32) .. "|state=finished|service=failed|skipped=0|outcome=failed" },
        { name = "finished disk-applied", suffix = "|id=" .. string.rep("b", 32) .. "|state=finished|service=pending|skipped=0|outcome=partial" }
    }) do
        for _, later_pending in ipairs({ false, true }) do
            it("orders pending strictly after " .. terminal.name .. "; later pending=" .. tostring(later_pending), function()
                local base = "12:00 19.10.2026|auto|updated=1|unchanged=0|failed=0"
                local older = base .. "|id=" .. string.rep("a", 32) .. "|state=pending|service=pending|skipped=0|outcome=pending\n"
                local completed = base .. terminal.suffix .. "\n"
                local newer = base .. "|id=" .. string.rep("c", 32) .. "|state=pending|service=pending|skipped=0|outcome=pending\n"
                begin({ fs = { ["/log"] = older .. completed .. (later_pending and newer or "") } })
                local r = H.reload("podkop-tweaker.subsched").status({}, "/log")
                assert.equal("12:00 19.10.2026", r.last_auto.ts)
                if terminal.name == "legacy" then assert.is_true(r.last_auto.legacy)
                else
                    assert.equal(string.rep("b", 32), r.last_auto.id)
                    assert.equal("finished", r.last_auto.state)
                end
                if later_pending then
                    assert.equal(string.rep("c", 32), r.last_auto_pending.id)
                    assert.equal("pending", r.last_auto_pending.state)
                else assert.is_nil(r.last_auto_pending) end
            end)
        end
    end

    it("returns the latest pending in file order when no auto completion is accepted", function()
        local function pending(ts, id)
            return ts .. "|auto|updated=1|unchanged=0|failed=0|id=" .. string.rep(id, 32) ..
                "|state=pending|service=pending|skipped=0|outcome=pending\n"
        end
        begin({ fs = { ["/log"] = pending("13:00 19.10.2026", "a") .. pending("12:00 19.10.2026", "b") } })
        local r = H.reload("podkop-tweaker.subsched").status({}, "/log")
        assert.is_nil(r.last_auto)
        assert.equal(string.rep("b", 32), r.last_auto_pending.id)
        assert.equal("12:00 19.10.2026", r.last_auto_pending.ts)
    end)

    it("does not let a malformed extension or manual completion hide the latest auto pending", function()
        local base = "12:00 19.10.2026|auto|updated=1|unchanged=0|failed=0"
        local pending = base .. "|id=" .. string.rep("a", 32) .. "|state=pending|service=pending|skipped=0|outcome=pending\n"
        begin({ fs = { ["/log"] = pending .. base .. "|state=finished\n" ..
            "12:00 19.10.2026|manual|updated=1|unchanged=0|failed=0\n" } })
        local r = H.reload("podkop-tweaker.subsched").status({}, "/log")
        assert.is_nil(r.last_auto)
        assert.equal(string.rep("a", 32), r.last_auto_pending.id)
    end)

    it("discards a cut extended pending header at the start of the bounded tail", function()
        local pending = "12:00 19.10.2026|auto|updated=1|unchanged=0|failed=0|id=" .. string.rep("a", 32) ..
            "|state=pending|service=pending|skipped=0|outcome=pending"
        begin({ fs = { ["/log"] = "partial-prefix" .. pending .. "\n" .. string.rep(" ", 65536 - #pending - 1) } })
        local r = H.reload("podkop-tweaker.subsched").status({}, "/log")
        assert.is_nil(r.last_auto)
        assert.is_nil(r.last_auto_pending)
        assert.equal(65536, r.log_window_bytes)
    end)

    it("accepts a fatal finished disk-applied event with service pending as completion, never as successful service work", function()
        begin({ fs = { ["/log"] = "12:00 19.10.2026|auto|updated=1|unchanged=0|failed=1|id=" .. string.rep("a", 32) ..
            "|state=finished|service=pending|skipped=0|outcome=partial\n" } })
        local r = H.reload("podkop-tweaker.subsched").status({}, "/log")
        assert.equal("finished", r.last_auto.state)
        assert.equal("pending", r.last_auto.service)
        assert.equal("partial", r.last_auto.outcome)
        assert.is_nil(r.last_auto_pending)
    end)

    it("does not promote malformed/incomplete extended headers to legacy completions or pending facts", function()
        local old = "11:00 19.10.2026|auto|updated=0|unchanged=1|failed=0\n"
        local base = "12:00 19.10.2026|auto|updated=1|unchanged=0|failed=0"
        begin({ fs = { ["/log"] = old .. base .. "|state=finished\n" .. base .. "|id=" .. string.rep("a", 32) ..
            "|state=pending|service=pending|skipped=0|outcome=pending|outcome=ok\n" } })
        local r = H.reload("podkop-tweaker.subsched").status({}, "/log")
        assert.equal("11:00 19.10.2026", r.last_auto.ts)
        assert.is_true(r.last_auto.legacy)
        assert.is_nil(r.last_auto_pending)
    end)

    for _, operation in ipairs({ "read", "close" }) do
        it("keeps both history facts unknown on bounded-tail " .. operation .. " failure", function()
            begin({ fs = { ["/log"] = "12:00 19.10.2026|auto|updated=0|unchanged=1|failed=0\n" },
                failures = { ["/log"] = { [operation] = true } } })
            local r = H.reload("podkop-tweaker.subsched").status({}, "/log")
            assert.is_nil(r.last_auto)
            assert.is_nil(r.last_auto_pending)
        end)
    end

    it("does not require crontab or allocate an input when the installed job is unchanged", function()
        local current = "# retain\n30 1,5,9,13,17,21 * * * /usr/bin/pt-auto-update\n"
        begin({ fs = { [ROOT_CRON] = current }, sys = { { match = "crontab ", out = "not installed\nPT_EXIT:127\n" } } })
        assert.is_true(H.reload("podkop-tweaker.subsched").setup_cron(4, "01:30"))
        assert.equal(current, H.vfs_read(ROOT_CRON))
        assert.same({}, H.stage_paths(CRON_STAGES))
        no_command("crontab ")
    end)

    for _, operation in ipairs({ "open", "read", "close" }) do
        it("preserves all cron jobs after a crontab " .. operation .. " failure", function()
            local current = "# retain\n0 3 * * * /usr/bin/other\n"
            begin({ fs = { [ROOT_CRON] = current }, failures = { [ROOT_CRON] = { [operation] = true } } })
            local ok, err = H.reload("podkop-tweaker.subsched").setup_cron(4, "01:30")
            assert.is_false(ok)
            assert.is_string(err)
            assert.equal(current, H.vfs_read(ROOT_CRON))
            no_command("crontab ")
            assert.same({}, H.stage_paths(CRON_STAGES))
        end)
    end

    for _, operation in ipairs({ "mktemp", "open", "write", "close" }) do
        it("does not install a failed private cron stage: " .. operation, function()
            local current = "0 3 * * * /usr/bin/other\n"
            begin({ fs = { [ROOT_CRON] = current, [CRON_INPUT] = "foreign input" },
                failures = { [CRON_STAGES] = { [operation] = true, partial = 5 } } })
            local ok, err = H.reload("podkop-tweaker.subsched").setup_cron(4, "01:30")
            assert.is_false(ok)
            assert.is_string(err)
            assert.equal(current, H.vfs_read(ROOT_CRON))
            assert.equal("foreign input", H.vfs_read(CRON_INPUT))
            no_command("crontab ")
            cleaned_inputs()
        end)
    end

    for _, output in ipairs({ "", "Looks successful without an exit marker", "\nPT_EXIT:bad\n", "not installed\nPT_EXIT:127\n" }) do
        it("rejects an unchecked or failed crontab result: " .. output, function()
            local current = "0 3 * * * /usr/bin/other\n"
            begin({ fs = { [ROOT_CRON] = current }, sys = { { match = "crontab ", out = output } } })
            local ok, err = H.reload("podkop-tweaker.subsched").setup_cron(4, "01:30")
            assert.is_false(ok)
            assert.matches("Cannot install crontab", err, 1, true)
            assert.equal(current, H.vfs_read(ROOT_CRON))
            cleaned_inputs()
        end)
    end

    it("reports cleanup failure after a successful installation and retains only the owned stage", function()
        local stage
        begin({ fs = { [ROOT_CRON] = "0 3 * * * /usr/bin/other\n", [CRON_INPUT] = "foreign input" },
            sys = { { match = "crontab ", out = function(command)
                stage = command:match("crontab '([^']+)'")
                H.vfs_write(ROOT_CRON, H.vfs_read(stage))
                H.state().failures[stage] = { remove = true }
                return "\nPT_EXIT:0\n"
            end } } })
        local ok, err, applied = H.reload("podkop-tweaker.subsched").setup_cron(4, "01:30")
        assert.is_false(ok)
        assert.is_true(applied)
        assert.matches("Cannot remove private crontab input", err, 1, true)
        assert.matches("0 3 * * * /usr/bin/other", H.vfs_read(ROOT_CRON), 1, true)
        assert.truthy(H.vfs_exists(stage))
        assert.equal("foreign input", H.vfs_read(CRON_INPUT))
    end)

    it("uses distinct physical inputs for repeated schedule changes", function()
        begin()
        local S = H.reload("podkop-tweaker.subsched")
        assert.is_true(S.setup_cron(4, "01:30"))
        assert.is_true(S.setup_cron(6, "02:15"))
        local stages = H.stage_paths(CRON_STAGES)
        assert.equal(2, #stages)
        assert.is_not.equal(stages[1], stages[2])
        for _, allocation in ipairs(H.allocations(CRON_STAGES)) do assert.equal("600", allocation.mode) end
        cleaned_inputs()
        assert.falsy(H.vfs_exists(CRON_INPUT))
    end)

    it("holds the subscriptions lock across cron read/modify/install and rejects another coroutine", function()
        begin({ fs = { [ROOT_CRON] = "0 3 * * * /usr/bin/other\n" } })
        local S = H.reload("podkop-tweaker.subsched")
        local open = io.open
        local intercepted, competing, competing_err = false, nil, nil
        io.open = function(path, mode)
            local fd, err, errno = open(path, mode)
            if path == ROOT_CRON and not intercepted then
                intercepted = true
                assert.truthy(H.vfs_exists(LOCK))
                local job = coroutine.create(function() competing, competing_err = S.setup_cron(6, "02:15") end)
                local resumed, resume_err = coroutine.resume(job)
                assert.is_true(resumed, resume_err)
                assert.equal("dead", coroutine.status(job))
            end
            return fd, err, errno
        end
        assert.is_true(S.setup_cron(4, "01:30"))
        assert.is_true(intercepted)
        assert.is_false(competing)
        assert.is_string(competing_err)
        assert.equal(1, #H.stage_paths(CRON_STAGES))
        assert.equal("0 3 * * * /usr/bin/other\n30 1,5,9,13,17,21 * * * /usr/bin/pt-auto-update\n", H.vfs_read(ROOT_CRON))
        assert.falsy(H.vfs_exists(LOCK))
    end)

    it("is reentrant under a caller's subscriptions lock and releases it only at the outer boundary", function()
        begin()
        local SRV = require("podkop-tweaker.services")
        local S = H.reload("podkop-tweaker.subsched")
        local ok, err = SRV.with_lock("subscriptions", function()
            local applied, apply_err = S.apply(4, "01:30", true)
            assert.is_true(applied, apply_err)
            assert.truthy(H.vfs_exists(LOCK))
            return true
        end)
        assert.is_true(ok, err)
        local acquired, released = 0, 0
        for _, event in ipairs(H.state().io_log) do
            if event.path == LOCK and event.success then
                if event.operation == "mkdir" then acquired = acquired + 1 end
                if event.operation == "rmdir" then released = released + 1 end
            end
        end
        assert.equal(1, acquired)
        assert.equal(1, released)
        assert.falsy(H.vfs_exists(LOCK))
    end)

    it("does not steal a held subscriptions lock or change launcher/hook/cron bytes", function()
        begin({ fs = { [ROOT_CRON] = "other jobs\n", [LAUNCHER] = "old launcher", [HOTPLUG] = "old hook" } })
        H.vfs_mkdir(LOCK)
        local ok, err = H.reload("podkop-tweaker.subsched").apply(4, "01:30", true)
        assert.is_false(ok)
        assert.is_string(err)
        assert.equal("other jobs\n", H.vfs_read(ROOT_CRON))
        assert.equal("old launcher", H.vfs_read(LAUNCHER))
        assert.equal("old hook", H.vfs_read(HOTPLUG))
        assert.truthy(H.vfs_exists(LOCK))
        assert.same({}, H.stage_paths("*"))
        no_command("crontab ")
    end)

    it("reports applied/unknown lock-release failure without repeating installation", function()
        begin({ failures = { [LOCK] = { rmdir = true } } })
        local S = H.reload("podkop-tweaker.subsched")
        local ok, err, applied, unknown = S.apply(4, "01:30", true)
        assert.is_false(ok)
        assert.is_string(err)
        assert.is_true(applied)
        assert.is_true(unknown)
        local installed = H.vfs_read(ROOT_CRON)
        local inputs = #H.stage_paths(CRON_STAGES)
        assert.is_false(S.apply(6, "02:15", false))
        assert.equal(installed, H.vfs_read(ROOT_CRON))
        assert.equal(inputs, #H.stage_paths(CRON_STAGES))
        assert.truthy(H.vfs_exists(LOCK))
        cleaned_inputs()
    end)

    it("does not call an unchanged disabled scheduler applied merely because release failed", function()
        begin({ failures = { [LOCK] = { rmdir = true } } })
        local ok, err, applied, unknown = H.reload("podkop-tweaker.subsched").apply(0, "", false)
        assert.is_false(ok)
        assert.is_false(applied)
        assert.is_true(unknown)
        assert.matches("cannot release owned lock", err, 1, true)
        assert.falsy(H.vfs_exists(LAUNCHER))
        assert.falsy(H.vfs_exists(HOTPLUG))
        assert.same({}, H.stage_paths("*"))
        assert.truthy(H.vfs_exists(LOCK))
        no_command("crontab ")
    end)

    it("distinguishes an unchanged cron result from an installed cron when releasing the lock fails", function()
        local current = "# retain\n30 1,5,9,13,17,21 * * * /usr/bin/pt-auto-update\n"
        begin({ fs = { [ROOT_CRON] = current }, failures = { [LOCK] = { rmdir = true } } })
        local ok, err, applied, unknown = H.reload("podkop-tweaker.subsched").setup_cron(4, "01:30")
        assert.is_false(ok)
        assert.is_false(applied)
        assert.is_true(unknown)
        assert.matches("cannot release owned lock", err, 1, true)
        assert.equal(current, H.vfs_read(ROOT_CRON))
        assert.same({}, H.stage_paths(CRON_STAGES))
        no_command("crontab ")
    end)

    for _, failure in ipairs({ "read", "mktemp" }) do
        it("preserves the primary pre-install " .. failure .. " error after release failure without asserting applied", function()
            local current = "0 3 * * * /usr/bin/other\n"
            local target = failure == "read" and ROOT_CRON or CRON_STAGES
            begin({ fs = { [ROOT_CRON] = current }, failures = { [target] = { [failure] = true }, [LOCK] = { rmdir = true } } })
            local ok, err, applied, unknown = H.reload("podkop-tweaker.subsched").setup_cron(4, "01:30")
            assert.is_false(ok)
            assert.is_false(applied)
            assert.is_true(unknown)
            local primary = failure == "read" and "Cannot read: Injected read failure" or "Cannot allocate an owned temporary file"
            assert.equal(primary, err:sub(1, #primary))
            assert.matches("cannot release owned lock", err, 1, true)
            assert.equal(current, H.vfs_read(ROOT_CRON))
            assert.truthy(H.vfs_exists(LOCK))
            cleaned_inputs()
            no_command("crontab ")
        end)
    end

    for _, release_failure in ipairs({ false, true }) do
        it("keeps an unacknowledged crontab command unknown rather than applied; release failure=" .. tostring(release_failure), function()
            local output = "crontab transport lost the exit marker"
            begin({ fs = { [ROOT_CRON] = "0 3 * * * /usr/bin/other\n" },
                failures = release_failure and { [LOCK] = { rmdir = true } } or {},
                sys = { { match = "crontab ", out = function(command)
                    local stage = command:match("crontab '([^']+)'")
                    H.vfs_write(ROOT_CRON, H.vfs_read(stage))
                    return output
                end } } })
            local ok, err, applied, unknown = H.reload("podkop-tweaker.subsched").setup_cron(4, "01:30")
            assert.is_false(ok)
            assert.is_false(applied, "the coordinator did not receive checked installation evidence")
            assert.is_true(unknown)
            local primary = "Cannot install crontab: " .. output
            assert.equal(primary, err:sub(1, #primary))
            if release_failure then assert.matches("cannot release owned lock", err, 1, true) end
            assert.matches("30 1,5,9,13,17,21 * * * /usr/bin/pt-auto-update", H.vfs_read(ROOT_CRON), 1, true)
            cleaned_inputs()
        end)
    end

    it("retains checked installation evidence and primary cleanup diagnostics when lock release also fails", function()
        local stage
        begin({ failures = { [LOCK] = { rmdir = true } }, sys = { { match = "crontab ", out = function(command)
            stage = command:match("crontab '([^']+)'")
            H.vfs_write(ROOT_CRON, H.vfs_read(stage))
            H.state().failures[stage] = { remove = true }
            return "\nPT_EXIT:0\n"
        end } } })
        local ok, err, applied, unknown = H.reload("podkop-tweaker.subsched").setup_cron(4, "01:30")
        assert.is_false(ok)
        assert.is_true(applied)
        assert.is_true(unknown)
        local primary = "Cannot remove private crontab input: Injected remove failure"
        assert.equal(primary, err:sub(1, #primary))
        assert.matches("cannot release owned lock", err, 1, true)
        assert.truthy(H.vfs_exists(stage))
        assert.truthy(H.vfs_exists(LOCK))
    end)

    for _, operation in ipairs({ "open", "read", "close", "remove" }) do
        it("reports existing empty hotplug-hook " .. operation .. " failure without treating it as absent", function()
            begin({ fs = { [HOTPLUG] = "" }, failures = { [HOTPLUG] = { [operation] = true } } })
            local ok, err = H.reload("podkop-tweaker.subsched").setup_hotplug(false)
            assert.is_false(ok)
            assert.is_string(err)
            assert.truthy(H.vfs_exists(HOTPLUG))
        end)
    end

    it("does not install after a bounded crontab read rejects oversized source bytes", function()
        local current = "#" .. string.rep("x", 65536)
        begin({ fs = { [ROOT_CRON] = current } })
        local ok, err = H.reload("podkop-tweaker.subsched").setup_cron(4, "01:30")
        assert.is_false(ok)
        assert.matches("size limit", err, 1, true)
        assert.equal(current, H.vfs_read(ROOT_CRON))
        assert.same({}, H.stage_paths(CRON_STAGES))
        no_command("crontab ")
    end)

    for _, output in ipairs({ "", "Cannot create directory\nPT_EXIT:1\n" }) do
        it("keeps the current hotplug hook after an unchecked/failed directory setup", function()
            begin({ fs = { [HOTPLUG] = "old hook" },
                sys = { { match = "(mkdir -p /etc/hotplug.d/iface)", out = output } } })
            local ok, err = H.reload("podkop-tweaker.subsched").setup_hotplug(true)
            assert.is_false(ok)
            assert.matches("Cannot create hotplug directory", err, 1, true)
            assert.equal("old hook", H.vfs_read(HOTPLUG))
            assert.same({}, H.stage_paths(HOTPLUG .. ".tmp-write.*"))
        end)
    end
end)
