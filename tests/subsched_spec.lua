package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path
local H = require("pt_harness")
after_each(function() H.finish() end)
local function begin(opts)
    opts = opts or {}
    H.begin(opts)
    for path, content in pairs(opts.fs or {}) do H.vfs_write(path, content) end
end

describe("subscription scheduler setup and observation", function()
    it("preserves unrelated crontab entries and replaces only the app job", function()
        local installed
        begin({ fs = { ["/etc/crontabs/root"] = "# keep\n0 3 * * * /usr/bin/other\n0 0 * * * /usr/bin/pt-auto-update\n" },
            sys = { { match = "crontab ", out = function()
                installed = H.vfs_read("/tmp/pt-subscriptions.cron")
                return "\nPT_EXIT:0\n"
            end } } })
        local S = H.reload("podkop-tweaker.subsched")
        assert.is_true(S.setup_cron(4, "01:30"))
        assert.equal("# keep\n0 3 * * * /usr/bin/other\n30 1,5,9,13,17,21 * * * /usr/bin/pt-auto-update\n", installed)
        assert.falsy(H.vfs_exists("/tmp/pt-subscriptions.cron"))
    end)

    it("does not replace a crontab that cannot be read or safely staged", function()
        H.begin({ failures = { ["/etc/crontabs/root"] = { open = true } } })
        local S = H.reload("podkop-tweaker.subsched")
        assert.is_false(S.setup_cron(4, "01:30"))
        assert.same({}, H.exec_cmds())
        H.finish()
        H.begin({ execute = { { match = "chmod 600", out = 1 } } })
        S = H.reload("podkop-tweaker.subsched")
        assert.is_false(S.setup_cron(4, "01:30"))
        assert.same({}, H.exec_cmds())
        assert.falsy(H.vfs_exists("/tmp/pt-subscriptions.cron"))
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
        assert.same({ ts = "08:00 09.10.2026", updated = 0, unchanged = 2, failed = 1 }, r.last_auto)
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
        H.begin({ execute = { { match = "chmod 755", out = 1 } }, sys = { { match = "crontab ", out = "not found\nPT_EXIT:127\n" } } })
        local S = H.reload("podkop-tweaker.subsched")
        assert.is_true(S.apply(0, "", false))
        assert.falsy(H.vfs_exists("/usr/bin/pt-auto-update"))
        assert.same({}, H.exec_cmds())
    end)
    it("bundle import reports a scheduler failure after saving subscriptions", function()
        H.begin({ failures = { ["/usr/bin/pt-auto-update.tmp-write"] = { write = true } } })
        local B = H.reload("podkop-tweaker.bundle")
        local ok, err = B.apply_item("subs", { data = { settings = {
            auto_update_interval = 4, auto_update_start = "01:30", auto_update_on_restart = true
        } } }, { subs_file = "/subs" })
        assert.is_false(ok)
        assert.matches("Subscriptions saved, but scheduling failed", err)
        assert.truthy(H.vfs_exists("/subs"))
        assert.falsy(H.vfs_exists("/usr/bin/pt-auto-update"))
    end)
end)
