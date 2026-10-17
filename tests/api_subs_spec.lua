-- api_subs_spec | v1.0.0 | 23.08.2026 | Max-coverage specs for V2 pure handlers of api_subs

package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path

local H = require("pt_harness")

local SUBS = "/etc/config/podkop-tweaker-subs.json"
local LOG = "/etc/config/pt-update.log"
local CFG = "/etc/config/podkop"
local SUBBAK = "/etc/config/podkop.sub-backup"

local LINK_OLD = "vless://old@srv:443?security=tls#OldName"
local LINK_A = "vless://a@x:1#a"
local LINK_B = "vless://b@x:2#b"

local CFG_TEXT = table.concat({
    "config section 'main'",
    "\toption connection_type 'proxy'",
    "\toption proxy_config_type 'url'",
    "\toption proxy_string '" .. LINK_OLD .. "'",
    "",
    "config section 'multi'",
    "\toption connection_type 'proxy'",
    "\toption proxy_config_type 'urltest'",
    "\tlist urltest_proxy_links '" .. LINK_A .. "'",
    "\tlist urltest_proxy_links '" .. LINK_B .. "'",
    ""
}, "\n")

local UCI_SEED = {
    podkop = {
        H.sec("main", "section", {
            connection_type = "proxy",
            proxy_config_type = "url",
            proxy_string = LINK_OLD
        }),
        H.sec("multi", "section", {
            connection_type = "proxy",
            proxy_config_type = "urltest",
            urltest_proxy_links = { LINK_A, LINK_B }
        })
    }
}

local function b64(data)
    local B = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        out[#out + 1] = B:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
        out[#out + 1] = B:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
        out[#out + 1] = (b and B:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "=")
        out[#out + 1] = (c and B:sub(n % 64 + 1, n % 64 + 1) or "=")
    end
    return table.concat(out)
end

local function copy_uci(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, item in pairs(value) do copy[key] = copy_uci(item) end
    return copy
end

local function begin_subs(opts)
    opts = opts or {}
    -- The harness keeps this database by reference. Each request world needs
    -- its own copy so a previous actor/test cannot mutate the shared seed.
    opts.uci = copy_uci(opts.uci or UCI_SEED)
    H.begin(opts)
    if not H.vfs_exists(CFG) then H.vfs_write(CFG, CFG_TEXT) end
    return H.reload("podkop-tweaker.api_subs")
end

local function mktemp_world(payload)
    return {
        popen = function(cmd)
            if cmd:find("curl", 1, true) then return (payload or H.vfs_read("/tmp/pt-fixed") or "") .. "\nPT_CURL_EXIT:0\n" end
            return ""
        end
    }, payload
end

local function command_count(needle)
    local n = 0
    for _, commands in ipairs({ H.exec_cmds(), H.execute_cmds() }) do
        for _, command in ipairs(commands) do
            if command:find(needle, 1, true) then n = n + 1 end
        end
    end
    return n
end

local function restart_count()
    return command_count("/etc/init.d/podkop restart")
end

after_each(function()
    H.finish()
end)

describe("api_subs.subscription_state", function()
    it("isolates UCI fixtures across worlds, including nested proxy-link lists", function()
        begin_subs({})
        require("luci.model.uci").cursor():set("podkop", "main", "proxy_config_type", "selector")
        H.state().uci.podkop[2].urltest_proxy_links[1] = "vless://changed@x:9#changed"
        assert.equal("url", UCI_SEED.podkop[1].proxy_config_type)
        assert.equal(LINK_A, UCI_SEED.podkop[2].urltest_proxy_links[1])
        H.finish()
        local api = begin_subs({})
        local response = api.subscription_state()
        assert.equal("url", response.sections[1].proxy_config_type)
        assert.equal(LINK_A, response.sections[2].slots[1].proxy.link)
    end)

    it("maps sections, slots, proxies and stored subscriptions", function()
        local SUB = begin_subs({})
        H.vfs_write(SUBS, '{"multi":[{"subscription_url":"https://s/1","proxy_name":"a","last_updated":"x"},null]}')
        local r = SUB.subscription_state()
        assert.equal(2, #r.sections)

        local main = r.sections[1]
        assert.equal("main", main.name)
        assert.equal("url", main.proxy_config_type)
        assert.equal(0, main.slots[1].index)
        assert.equal("OldName", main.slots[1].proxy.name)
        assert.equal("VLESS", main.slots[1].proxy.protocol)
        assert.equal("srv", main.slots[1].proxy.server)
        assert.equal("443", main.slots[1].proxy.port)
        assert.equal("tls", main.slots[1].proxy.security)
        assert.is_nil(main.slots[1].subscription)

        local multi = r.sections[2]
        assert.equal(2, #multi.slots)
        assert.equal(1, multi.slots[2].index)
        assert.equal("https://s/1", multi.slots[1].subscription.subscription_url)
        assert.is_nil(multi.slots[2].subscription)
    end)

    it("empty world -> empty sections", function()
        H.begin({})
        local r = H.reload("podkop-tweaker.api_subs").subscription_state()
        assert.same({ sections = {} }, r)
    end)
end)

describe("api_subs.subscription_fetch", function()
    local function begin_fetch(payload)
        local o = mktemp_world(payload)
        local SUB = begin_subs(o)
        H.vfs_write("/tmp/pt-fixed", payload or "")
        return SUB
    end

    it("empty url rejected", function()
        local SUB = begin_fetch("")
        assert.same({ error = "URL is required" }, SUB.subscription_fetch(""))
    end)

    it("non-http scheme rejected", function()
        local SUB = begin_fetch("")
        assert.same({ error = "Only HTTP(S) URLs allowed" }, SUB.subscription_fetch("ftp://h/x"))
    end)

    it("happy plaintext payload with warning flag for http://", function()
        local SUB = begin_fetch(LINK_A .. "\n")
        local r = SUB.subscription_fetch("http://sub.example/x")
        assert.is_true(r.success)
        assert.is_true(r.http_warning)
        assert.equal(1, #r.proxies)
        assert.equal("a", r.proxies[1].name)
        for _, call in ipairs(H.state().io_log) do
            assert.falsy(call.operation == "open" and call.mode:sub(1, 1) == "w", "subscription download must not write an unbounded temporary file")
        end
    end)

    it("base64 payload decoded", function()
        local SUB = begin_fetch(b64("vmess://xyz@h:8443#Vm\n"))
        local r = SUB.subscription_fetch("https://sub.example/x")
        assert.is_true(r.success)
        assert.is_false(r.http_warning)
        assert.equal("Vm", r.proxies[1].name)
        assert.equal("VMESS", r.proxies[1].protocol)
    end)

    it("producer failure -> download error", function()
        local SUB = begin_subs({ popen = function() return "\nPT_CURL_EXIT:7\n" end })
        assert.equal("Failed to download subscription", SUB.subscription_fetch("https://sub.example/x").error)
    end)

    it("no links in payload -> exact error", function()
        local SUB = begin_fetch("just text\n")
        assert.same({ error = "No proxy links found in subscription" },
            SUB.subscription_fetch("https://sub.example/x"))
    end)
end)

describe("api_subs.subscription_attach", function()
    it("invalid index variants -> missing params", function()
        local SUB = begin_subs({})
        for _, idx in ipairs({ "-1", "1000", "abc" }) do
            assert.same({ error = "Missing required parameters" },
                SUB.subscription_attach("main", idx, "https://s", "p", LINK_OLD))
        end
        assert.equal(0, #H.exec_cmds())
    end)

    it("empty section or link -> missing params", function()
        local SUB = begin_subs({})
        assert.same({ error = "Missing required parameters" },
            SUB.subscription_attach("", "0", "u", "p", LINK_A))
        assert.same({ error = "Missing required parameters" },
            SUB.subscription_attach("main", "0", "u", "p", ""))
    end)

    it("bad section name -> sanitized rejection", function()
        local SUB = begin_subs({})
        assert.same({ error = "Invalid section name" },
            SUB.subscription_attach("../etc", "0", "u", "p", LINK_A))
    end)

    it("bad link scheme -> format rejection", function()
        local SUB = begin_subs({})
        -- NOTE: any ^%w+:// scheme is accepted by V1 contract (ftp:// included)
        assert.same({ error = "Invalid proxy link format" },
            SUB.subscription_attach("main", "0", "u", "p", "plainlink"))
    end)

    it("unknown section -> not found", function()
        local SUB = begin_subs({})
        assert.same({ error = "Section not found or not a proxy section" },
            SUB.subscription_attach("ghost", "0", "https://s", "p", LINK_A))
    end)

    it("unchanged link: only subs+log updated, no restart, no sub-backup", function()
        local SUB = begin_subs({})
        local r = SUB.subscription_attach("main", "0", "https://sub/1", "OldName", LINK_OLD)
        assert.same({ success = true, unchanged = true }, r)
        assert.falsy(H.vfs_exists(SUBBAK))
        local restarts = 0
        for _, c in ipairs(H.exec_cmds()) do
            if c:find("/etc/init.d/podkop restart", 1, true) then restarts = restarts + 1 end
        end
        assert.equal(0, restarts)
        local subs = require("pt-subs-lib").read_subs(SUBS)
        assert.equal("https://sub/1", subs.main[1].subscription_url)
        assert.matches("%(manual%)", subs.main[1].last_updated)
        local log = H.vfs_read(LOG)
        assert.truthy(log:find("unchanged=1", 1, true))
        assert.truthy(log:find("OldName: unchanged", 1, true))
    end)

    it("unchanged write failure -> exact error", function()
        local SUB = begin_subs({ failures = { [SUBS .. ".tmp.*"] = { write = true } } })
        local r = SUB.subscription_attach("main", "0", "https://sub/1", "OldName", LINK_OLD)
        assert.equal("Failed to save data", r.error)
        assert.is_string(r.details)
        assert.falsy(H.vfs_exists(SUBS))
        assert.equal(0, restart_count())
    end)

    it("changed link on url section: backup, replace, subs, checked restart request, log", function()
        local SUB = begin_subs({})
        local new_link = "vless://new@n:443#NewName"
        local r = SUB.subscription_attach("main", "0", "https://sub/2", "NewName", new_link)
        assert.is_true(r.success)
        assert.is_true(r.restarting)
        assert.is_true(r.verification_required)
        local cfg = H.vfs_read(CFG)
        assert.truthy(cfg:find("proxy_string '" .. new_link .. "'", 1, true))
        assert.falsy(cfg:find(LINK_OLD, 1, true))
        assert.equal(CFG_TEXT, H.vfs_read(SUBBAK))
        assert.equal(1, restart_count())
        local log = H.vfs_read(LOG)
        assert.truthy(log:find("updated=1", 1, true))
        assert.truthy(log:find("NewName: updated", 1, true))
        local subs = require("pt-subs-lib").read_subs(SUBS)
        assert.equal("https://sub/2", subs.main[1].subscription_url)
    end)

    it("changed link on urltest slot replaces exact list line", function()
        local SUB = begin_subs({})
        local new_link = "vless://bb@x:9#bb"
        assert.is_true(SUB.subscription_attach("multi", "1", "https://s", "bb", new_link).restarting)
        local cfg = H.vfs_read(CFG)
        assert.truthy(cfg:find("list urltest_proxy_links '" .. new_link .. "'", 1, true))
        assert.truthy(cfg:find("list urltest_proxy_links '" .. LINK_A .. "'", 1, true))
        assert.falsy(cfg:find(LINK_B, 1, true))
    end)

    it("uci/cfg mismatch -> replace error passthrough", function()
        local SUB = begin_subs({})
        H.vfs_write(CFG, "config unrelated 'x'\n")
        assert.same({ error = "Proxy link not found in config" },
            SUB.subscription_attach("main", "0", "https://s", "p", "vless://z@z:1#z"))
    end)

    it("changed path write failure -> exact error", function()
        local SUB = begin_subs({ failures = { [SUBS .. ".tmp.*"] = { close = true } } })
        local r = SUB.subscription_attach("main", "0", "https://s", "p", "vless://z@z:1#z")
        assert.equal("Failed to save data", r.error)
        assert.equal(CFG_TEXT, H.vfs_read(CFG))
        assert.falsy(H.vfs_exists(SUBBAK))
        assert.falsy(H.vfs_exists(SUBS))
        assert.equal(0, restart_count())
    end)
end)

describe("api_subs.subscription_detach", function()
    it("invalid params rejected", function()
        local SUB = begin_subs({})
        assert.same({ error = "Missing required parameters" }, SUB.subscription_detach("", "0"))
        assert.same({ error = "Missing required parameters" }, SUB.subscription_detach("main", "1000"))
        assert.same({ error = "Invalid section name" }, SUB.subscription_detach("bad name", "0"))
    end)

    it("removes existing slot entry", function()
        local SUB = begin_subs({})
        H.vfs_write(SUBS, '{"main":[{"subscription_url":"https://s/1","proxy_name":"OldName"}]}')
        assert.same({ success = true }, SUB.subscription_detach("main", "0"))
        local subs = require("pt-subs-lib").read_subs(SUBS)
        assert.is_nil(subs.main[1])
    end)

    it("absent slot -> success without write", function()
        local SUB = begin_subs({})
        local S = require("pt-subs-lib")
        local called = false
        S.write_subs = function() called = true; return true end
        assert.same({ success = true }, SUB.subscription_detach("main", "0"))
        assert.is_false(called)
    end)

    it("write failure -> exact error", function()
        local SUB = begin_subs({})
        H.vfs_write(SUBS, '{"main":[{"subscription_url":"https://s/1","proxy_name":"OldName"}]}')
        local S = require("pt-subs-lib")
        S.write_subs = function() return false end
        assert.same({ error = "Failed to save data" }, SUB.subscription_detach("main", "0"))
    end)
end)

describe("api_subs.settings_read", function()
    it("defaults when no settings stored", function()
        local SUB = begin_subs({})
        assert.same({
            auto_update_interval = 0,
            auto_update_start = "",
            auto_update_on_restart = false,
            log_display_count = 10
        }, SUB.settings_read())
    end)

    it("returns stored settings", function()
        local SUB = begin_subs({})
        H.vfs_write(SUBS, '{"settings":{"auto_update_interval":4,"auto_update_start":"01:30",' ..
            '"auto_update_on_restart":true,"log_display_count":7}}')
        assert.same({
            auto_update_interval = 4,
            auto_update_start = "01:30",
            auto_update_on_restart = true,
            log_display_count = 7
        }, SUB.settings_read())
    end)
end)

describe("api_subs.settings_save", function()
    local function read_subs_json()
        return require("pt-subs-lib").read_subs(SUBS)
    end

    it("interval out of range rejected", function()
        local SUB = begin_subs({})
        assert.same({ error = "Interval must be 1-24 hours" }, SUB.settings_save("25", "01:30", false, "10"))
        assert.same({ error = "Interval must be 1-24 hours" }, SUB.settings_save("0.5", "01:30", false, "10"))
    end)

    it("start time format and value validation", function()
        local SUB = begin_subs({})
        assert.same({ error = "Invalid start time, use HH:MM" }, SUB.settings_save("4", "9:30", false, "10"))
        assert.same({ error = "Invalid start time value" }, SUB.settings_save("4", "25:00", false, "10"))
        assert.same({ error = "Invalid start time value" }, SUB.settings_save("4", "00:60", false, "10"))
    end)

    it("interval 0: resets schedule, removes hotplug, clamps log count", function()
        local SUB = begin_subs({})
        H.vfs_write("/etc/hotplug.d/iface/99-pt-subs", "old")
        H.vfs_write("/etc/crontabs/root", "0 0 * * * /usr/bin/pt-auto-update\n")
        assert.same({ success = true }, SUB.settings_save("0", "01:30", false, "100"))
        local st = read_subs_json().settings
        assert.equal(0, st.auto_update_interval)
        assert.equal("", st.auto_update_start)
        assert.equal(false, st.auto_update_on_restart)
        assert.equal(25, st.log_display_count)
        assert.falsy(H.vfs_exists("/usr/bin/pt-auto-update"), "disabled triggers do not need a launcher")
        local cleanup = false
        for _, c in ipairs(H.exec_cmds()) do
            if c:find("crontab '/tmp/pt-subscriptions.cron", 1, true) then cleanup = true end
        end
        assert.truthy(cleanup)
        assert.falsy(H.vfs_exists("/etc/hotplug.d/iface/99-pt-subs"))
    end)

    it("valid interval: cron hours computed, hotplug written when enabled", function()
        local installed
        local SUB = begin_subs({ sys = { { match = "crontab '/tmp/pt-subscriptions.cron", out = function(cmd)
            local stage = cmd:match("crontab '([^']+)'")
            assert.equal(H.last_stage("/tmp/pt-subscriptions.cron.tmp-write.*"), stage)
            installed = H.vfs_read(stage)
            return "\nPT_EXIT:0\n"
        end } } })
        assert.same({ success = true }, SUB.settings_save("4", "01:30", true, "5"))
        local st = read_subs_json().settings
        assert.equal(4, st.auto_update_interval)
        assert.equal("01:30", st.auto_update_start)
        assert.equal(5, st.log_display_count)
        assert.equal("30 1,5,9,13,17,21 * * * /usr/bin/pt-auto-update\n", installed)
        local hp = H.vfs_read("/etc/hotplug.d/iface/99-pt-subs")
        assert.truthy(hp:find("ifup", 1, true))
        assert.truthy(hp:find("pt%-auto%-update"))
    end)

    it("log display clamped up to 1", function()
        local SUB = begin_subs({})
        assert.same({ success = true }, SUB.settings_save("0", "", false, "0"))
        assert.equal(1, read_subs_json().settings.log_display_count)
    end)

    it("write failure -> exact error", function()
        local SUB = begin_subs({})
        local S = require("pt-subs-lib")
        S.write_subs = function() return false end
        assert.same({ error = "Failed to save settings" }, SUB.settings_save("0", "", false, "10"))
    end)

    it("log-only save preserves schedule, slots and unknown fields without scheduler commands", function()
        local SUB = begin_subs({})
        H.vfs_write(SUBS, '{"settings":{"auto_update_interval":4,"auto_update_start":"01:30","auto_update_on_restart":true,"future":"keep"},"main":[{"subscription_url":"https://s"}]}')
        assert.same({ success = true }, SUB.settings_save(nil, nil, nil, "15", true))
        local data = read_subs_json()
        assert.equal(4, data.settings.auto_update_interval)
        assert.equal("01:30", data.settings.auto_update_start)
        assert.is_true(data.settings.auto_update_on_restart)
        assert.equal("keep", data.settings.future)
        assert.equal(15, data.settings.log_display_count)
        assert.equal("https://s", data.main[1].subscription_url)
        assert.equal(0, command_count("crontab "))
        assert.equal(0, restart_count())
        assert.falsy(H.vfs_exists("/usr/bin/pt-auto-update"))
    end)

    it("reports launcher and cron failures instead of claiming complete setup success", function()
        local SUB = begin_subs({ failures = { ["/usr/bin/pt-auto-update.tmp-write.*"] = { write = true } } })
        local r = SUB.settings_save("4", "01:30", true, "10")
        assert.is_false(r.success)
        assert.is_true(r.settings_saved)
        assert.equal(4, read_subs_json().settings.auto_update_interval)
        assert.equal(0, command_count("crontab "))
        H.finish()
        SUB = begin_subs({ sys = { { match = "crontab ", out = "permission denied\nPT_EXIT:1\n" } } })
        r = SUB.settings_save("4", "01:30", true, "10")
        assert.is_false(r.success)
        assert.matches("permission denied", r.details)
        assert.truthy(H.vfs_exists("/etc/hotplug.d/iface/99-pt-subs"), "independent WAN setup still runs after cron failure")
    end)
end)

describe("api_subs.update_all", function()
    local SUB_ENTRY = '{"main":[{"subscription_url":"https://sub/1","proxy_name":"OldName"}]}'

    it("updated: real pipeline replaces link, restarts, logs", function()
        local SUB = begin_subs(mktemp_world(nil))
        H.vfs_write(SUBS, SUB_ENTRY)
        H.vfs_write("/tmp/pt-fixed", "vless://fresh@f:443#OldName\n")
        local r = SUB.update_all()
        assert.is_true(r.success)
        assert.equal(1, r.updated)
        assert.equal(0, r.unchanged)
        assert.equal(0, r.failed)
        assert.is_true(r.restarted)
        assert.is_true(r.verification_required)
        assert.truthy(H.vfs_read(CFG):find("vless://fresh@f:443#OldName", 1, true))
        assert.equal(1, restart_count())
        assert.truthy(H.vfs_read(LOG):find("updated=1", 1, true))
        local subs = require("pt-subs-lib").read_subs(SUBS)
        assert.matches("%(manual%)", subs.main[1].last_updated)
    end)

    it("unchanged: same link -> no restart", function()
        local SUB = begin_subs(mktemp_world(nil))
        H.vfs_write(SUBS, SUB_ENTRY)
        H.vfs_write("/tmp/pt-fixed", LINK_OLD .. "\n")
        local r = SUB.update_all()
        assert.is_true(r.success)
        assert.equal(0, r.updated)
        assert.equal(1, r.unchanged)
        assert.equal(0, r.failed)
        assert.is_false(r.restarted)
        assert.equal(0, restart_count())
    end)

    it("failed: garbage payload retries then reports", function()
        local SUB = begin_subs(mktemp_world(nil))
        H.vfs_write(SUBS, SUB_ENTRY)
        H.vfs_write("/tmp/pt-fixed", "garbage\n")
        local r = SUB.update_all()
        assert.is_true(r.success)
        assert.equal(0, r.updated)
        assert.equal(0, r.unchanged)
        assert.equal(1, r.failed)
        assert.is_false(r.restarted)
        local sleeps = 0
        for _, c in ipairs(H.execute_cmds()) do
            if c:find("^sleep 10") then sleeps = sleeps + 1 end
        end
        assert.equal(2, sleeps)
        assert.truthy(H.vfs_read(LOG):find("failed", 1, true))
    end)
end)

describe("subscription read failures are mutation barriers", function()
    local state = '{"version":8,"settings":{"auto_update_interval":4,"auto_update_start":"01:30",' ..
        '"auto_update_on_restart":true,"log_display_count":7,"future":"keep"},' ..
        '"main":[{"subscription_url":"https://sub/1","proxy_name":"OldName","future":"keep"}]}'
    local consumers = {
        { name = "state GET", call = function(api) return api.subscription_state() end },
        { name = "options GET", call = function(api) return api.settings_read() end },
        { name = "schedule status GET", call = function(api) return api.auto_update_status() end },
        { name = "log-only Save", call = function(api) return api.settings_save(nil, nil, nil, "20", true) end },
        { name = "options Save", call = function(api) return api.settings_save("0", "", false, "20") end },
        { name = "unchanged Attach", call = function(api) return api.subscription_attach("main", "0", "https://sub/2", "OldName", LINK_OLD) end },
        { name = "changed Attach", call = function(api) return api.subscription_attach("main", "0", "https://sub/2", "new", LINK_A) end },
        { name = "Detach", call = function(api) return api.subscription_detach("main", "0") end },
        { name = "Update All", call = function(api) return api.update_all() end }
    }
    local failures = {
        { name = "empty", bytes = "" }, { name = "whitespace", bytes = " \r\n" },
        { name = "malformed", bytes = '{"main":' }, { name = "wrong root type", bytes = "[]" },
        { name = "wrong settings type", bytes = '{"settings":false}' },
        { name = "wrong slot type", bytes = '{"main":["bad"]}' },
        { name = "open", failure = { open = true, errno = 5 } },
        { name = "read", failure = { read = true } }, { name = "close", failure = { close = true } }
    }
    for _, consumer in ipairs(consumers) do
        for _, failure in ipairs(failures) do
            it(consumer.name .. " preserves all bytes after " .. failure.name .. " failure", function()
                local api = begin_subs({ failures = failure.failure and { [SUBS] = failure.failure } or {} })
                local bytes = failure.bytes or state
                H.vfs_write(SUBS, bytes)
                H.vfs_write(SUBBAK, "last good config backup")
                H.vfs_write(LOG, "old journal\n")
                H.vfs_write("/etc/crontabs/root", "unrelated cron job\n")
                H.vfs_write("/etc/hotplug.d/iface/99-pt-subs", "current WAN hook\n")
                local response = consumer.call(api)
                assert.is_string(response.error)
                assert.falsy(response.success)
                assert.equal(bytes, H.vfs_read(SUBS))
                assert.equal(CFG_TEXT, H.vfs_read(CFG))
                assert.equal("last good config backup", H.vfs_read(SUBBAK))
                assert.equal("old journal\n", H.vfs_read(LOG))
                assert.equal("unrelated cron job\n", H.vfs_read("/etc/crontabs/root"))
                assert.equal("current WAN hook\n", H.vfs_read("/etc/hotplug.d/iface/99-pt-subs"))
                assert.equal(0, command_count("crontab "))
                assert.equal(0, restart_count())
                assert.same({}, H.stage_paths(), "a failed state read cannot prepare a writable replacement")
                for _, command in ipairs(H.popen_cmds()) do assert.falsy(command:find("curl", 1, true)) end
            end)
        end
    end

    it("first-use log Save creates state with defaults while existing unknown data survives later Saves", function()
        local api = begin_subs({})
        assert.is_true(api.settings_save(nil, nil, nil, "12", true).success)
        local s = require("pt-subs-lib")
        local first = assert(s.read_subs(SUBS))
        assert.equal(1, first.version)
        assert.equal(12, first.settings.log_display_count)
        assert.equal(0, api.settings_read().auto_update_interval)
        first.version, first.future = 8, { flag = "keep" }
        first.settings.future = "keep setting"
        assert.is_true(s.write_subs(first, SUBS))
        assert.is_true(api.settings_save("0", "", false, "15").success)
        local saved = assert(s.read_subs(SUBS))
        assert.equal(8, saved.version)
        assert.same({ flag = "keep" }, saved.future)
        assert.equal("keep setting", saved.settings.future)
    end)
end)

describe("subscription mutation IO and lock outcomes", function()
    local state = '{"main":[{"subscription_url":"https://sub/1","proxy_name":"OldName"}]}'
    local fresh = "vless://fresh@f:443#OldName"

    for _, action in ipairs({ "Detach", "options Save", "log Save" }) do
        for _, operation in ipairs({ "write", "close", "rename" }) do
            it(action .. " retains state and scheduling after an actual " .. operation .. " failure", function()
                local failure_path = operation == "rename" and SUBS or SUBS .. ".tmp.*"
                local api = begin_subs({ failures = { [failure_path] = { [operation] = true, partial = 4 } } })
                H.vfs_write(SUBS, state)
                H.vfs_write("/etc/crontabs/root", "unrelated cron job\n")
                H.vfs_write("/etc/hotplug.d/iface/99-pt-subs", "old hook\n")
                local response
                if action == "Detach" then response = api.subscription_detach("main", "0")
                elseif action == "options Save" then response = api.settings_save("4", "01:30", true, "12")
                else response = api.settings_save(nil, nil, nil, "12", true) end
                assert.is_string(response.error)
                assert.falsy(response.success)
                assert.equal(state, H.vfs_read(SUBS))
                assert.equal("unrelated cron job\n", H.vfs_read("/etc/crontabs/root"))
                assert.equal("old hook\n", H.vfs_read("/etc/hotplug.d/iface/99-pt-subs"))
                assert.equal(CFG_TEXT, H.vfs_read(CFG))
                assert.falsy(H.vfs_exists("/usr/bin/pt-auto-update"))
                assert.equal(0, command_count("crontab "))
                assert.equal(0, restart_count())
            end)
        end
    end

    for _, operation in ipairs({ "open", "write", "close" }) do
        it("stops Update All before config/backup mutation on state stage " .. operation .. " failure", function()
            local options = mktemp_world(fresh)
            options.failures = { [SUBS .. ".tmp.*"] = { [operation] = true, partial = 5 } }
            local api = begin_subs(options)
            H.vfs_write(SUBS, state)
            H.vfs_write(SUBBAK, "last good backup")
            H.vfs_write(LOG, "old journal\n")
            local response = api.update_all()
            assert.is_false(response.success)
            assert.is_string(response.error)
            assert.equal(0, response.updated)
            assert.equal(1, response.failed)
            assert.equal(state, H.vfs_read(SUBS))
            assert.equal(CFG_TEXT, H.vfs_read(CFG))
            assert.equal("last good backup", H.vfs_read(SUBBAK))
            assert.equal("old journal\n", H.vfs_read(LOG))
            assert.equal(0, restart_count())
            assert.same({}, H.stage_paths(CFG .. ".tmp.*"))
        end)
    end

    it("keeps state and backup when a config stage cannot be written", function()
        local options = mktemp_world(fresh)
        options.failures = { [CFG .. ".tmp.*"] = { write = true, partial = 5 } }
        local api = begin_subs(options)
        H.vfs_write(SUBS, state)
        H.vfs_write(SUBBAK, "last good backup")
        local response = api.update_all()
        assert.is_false(response.success)
        assert.equal(state, H.vfs_read(SUBS))
        assert.equal(CFG_TEXT, H.vfs_read(CFG))
        assert.equal("last good backup", H.vfs_read(SUBBAK))
        assert.equal(0, restart_count())
        for _, stage in ipairs(H.stage_paths(SUBS .. ".tmp.*")) do assert.falsy(H.vfs_exists(stage)) end
    end)

    it("reports final state publication failure as disk-applied partial work, with no restart/replay", function()
        local options = mktemp_world(fresh)
        options.failures = { [SUBS] = { rename = true } }
        local api = begin_subs(options)
        H.vfs_write(SUBS, state)
        H.vfs_write(LOG, "old journal\n")
        local response = api.update_all()
        assert.is_false(response.success)
        assert.is_true(response.applied)
        assert.is_true(response.restart_required)
        assert.is_false(response.restarted)
        assert.equal(1, response.updated)
        assert.equal(1, response.failed)
        assert.equal(state, H.vfs_read(SUBS))
        assert.truthy(H.vfs_read(CFG):find(fresh, 1, true))
        assert.equal(CFG_TEXT, H.vfs_read(SUBBAK))
        assert.equal("old journal\n", H.vfs_read(LOG))
        assert.equal(0, restart_count())
        local fetches = 0
        for _, command in ipairs(H.popen_cmds()) do if command:find("curl", 1, true) then fetches = fetches + 1 end end
        assert.equal(1, fetches)
        assert.equal(1, #H.stage_paths(CFG .. ".tmp.*"))
    end)

    it("reports an Attach state publication failure after config application", function()
        local api = begin_subs({ failures = { [SUBS] = { rename = true } } })
        H.vfs_write(SUBS, state)
        local response = api.subscription_attach("main", "0", "https://sub/2", "OldName", fresh)
        assert.is_false(response.success)
        assert.is_true(response.applied)
        assert.is_true(response.restart_required)
        assert.equal(state, H.vfs_read(SUBS))
        assert.truthy(H.vfs_read(CFG):find(fresh, 1, true))
        assert.equal(0, restart_count())
    end)

    it("does not claim success when the final journal cannot be published", function()
        local options = mktemp_world(LINK_OLD)
        options.failures = { [LOG .. ".tmp-write.*"] = { close = true } }
        local api = begin_subs(options)
        H.vfs_write(SUBS, state)
        H.vfs_write(LOG, "old journal\n")
        local response = api.update_all()
        assert.is_false(response.success)
        assert.matches("log", response.error)
        assert.is_string(response.details)
        assert.equal(1, response.unchanged)
        assert.is_true(response.applied)
        assert.equal("old journal\n", H.vfs_read(LOG))
        assert.equal(0, restart_count())
    end)

    it("an unchanged Attach reports an applied association when its journal fails", function()
        local api = begin_subs({ failures = { [LOG .. ".tmp-write.*"] = { write = true, partial = 3 } } })
        H.vfs_write(SUBS, state)
        H.vfs_write(LOG, "old journal\n")
        local response = api.subscription_attach("main", "0", "https://sub/2", "OldName", LINK_OLD)
        assert.is_false(response.success)
        assert.is_true(response.applied)
        assert.matches("log", response.error)
        assert.equal("https://sub/2", require("pt-subs-lib").read_subs(SUBS).main[1].subscription_url)
        assert.equal("old journal\n", H.vfs_read(LOG))
        assert.equal(CFG_TEXT, H.vfs_read(CFG))
        assert.equal(0, restart_count())
    end)

    it("returns checked restart failure with applied bytes and one request only", function()
        local options = mktemp_world(fresh)
        options.sys = { { match = "/etc/init.d/podkop restart", out = "restart denied\nPT_EXIT:1\n" } }
        local api = begin_subs(options)
        H.vfs_write(SUBS, state)
        local response = api.update_all()
        assert.is_false(response.success)
        assert.is_true(response.applied)
        assert.is_false(response.restarted)
        assert.is_true(response.restart_required)
        assert.matches("restart denied", response.details)
        assert.truthy(H.vfs_read(CFG):find(fresh, 1, true))
        assert.equal(1, restart_count())
        assert.truthy(H.vfs_read(LOG):find("podkop: failed", 1, true))
    end)

    it("a failed subscriptions lock acquisition leaves bytes untouched", function()
        local api = begin_subs({ failures = { ["/var/lock/podkop-tweaker-subscriptions.lock"] = { mkdir = true } } })
        H.vfs_write(SUBS, state)
        local response = api.settings_save(nil, nil, nil, "19", true)
        assert.is_false(response.success)
        assert.is_string(response.error)
        assert.equal(state, H.vfs_read(SUBS))
        assert.same({}, H.stage_paths())
    end)

    it("a release failure reports applied state and does not replay the Save", function()
        local api = begin_subs({ failures = { ["/var/lock/podkop-tweaker-subscriptions.lock"] = { rmdir = true } } })
        H.vfs_write(SUBS, state)
        local response = api.settings_save(nil, nil, nil, "19", true)
        assert.is_false(response.success)
        assert.is_true(response.applied)
        assert.equal(19, require("pt-subs-lib").read_subs(SUBS).settings.log_display_count)
        assert.equal(1, #H.stage_paths(SUBS .. ".tmp.*"))
        assert.truthy(H.state().dirs["/var/lock/podkop-tweaker-subscriptions.lock"])
    end)
end)

describe("subscription release failures preserve actual outcomes", function()
    local state = '{"version":7,"main":[{"subscription_url":"https://sub/1","proxy_name":"OldName"}]}'
    local sub_lock = "/var/lock/podkop-tweaker-subscriptions.lock"
    local podkop_lock = "/var/lock/podkop-tweaker-podkop.lock"
    local fresh = "vless://fresh@f:443#OldName"

    local mutations = {
        { name = "settings", call = function(api) return api.settings_save(nil, nil, nil, "19", true) end },
        { name = "Attach", call = function(api) return api.subscription_attach("main", "0", "https://sub/2", "OldName", fresh) end },
        { name = "Detach", call = function(api) return api.subscription_detach("main", "0") end }
    }
    for _, mutation in ipairs(mutations) do
        for _, failure in ipairs({ "read", "write" }) do
            it("does not label " .. mutation.name .. " applied after " .. failure .. " and release both fail", function()
                local failure_path = failure == "read" and SUBS or SUBS .. ".tmp.*"
                local api = begin_subs({ strict = true, failures = {
                    [failure_path] = { [failure] = true, partial = 4 }, [sub_lock] = { rmdir = true }
                } })
                H.vfs_write(SUBS, state)
                H.vfs_write(LOG, "old journal\n")
                local response = mutation.call(api)
                assert.is_false(response.success)
                assert.falsy(response.applied)
                assert.falsy(response.settings_saved)
                assert.is_true(response.unknown)
                assert.matches("cannot release owned lock", response.details)
                assert.truthy((response.error .. "\n" .. response.details):find(failure == "read" and "Cannot read subscriptions" or "Injected write failure", 1, true))
                assert.equal(state, H.vfs_read(SUBS))
                assert.equal(CFG_TEXT, H.vfs_read(CFG))
                assert.equal("old journal\n", H.vfs_read(LOG))
                assert.falsy(H.vfs_exists(SUBBAK))
                assert.equal(0, restart_count())
            end)
        end
    end

    it("keeps an unsuccessful Update All snapshot read and release error without fetching or claiming applied", function()
        local api = begin_subs({ strict = true, failures = { [SUBS] = { read = true }, [sub_lock] = { rmdir = true } } })
        H.vfs_write(SUBS, state)
        local response = api.update_all()
        assert.is_false(response.success)
        assert.falsy(response.applied)
        assert.is_true(response.unknown)
        assert.matches("Cannot read subscriptions", response.error)
        assert.matches("cannot release owned lock", response.error)
        assert.equal(0, response.updated)
        assert.equal(state, H.vfs_read(SUBS))
        assert.equal(CFG_TEXT, H.vfs_read(CFG))
        assert.same({}, H.stage_paths())
        assert.same({}, H.popen_cmds())
    end)

    it("does not label a no-op Detach applied when release fails", function()
        local api = begin_subs({ strict = true, failures = { [sub_lock] = { rmdir = true } } })
        H.vfs_write(SUBS, '{"version":7}')
        local response = api.subscription_detach("main", "0")
        assert.is_false(response.success)
        assert.falsy(response.applied)
        assert.is_true(response.unknown)
        assert.equal('{"version":7}', H.vfs_read(SUBS))
        assert.same({}, H.stage_paths())
    end)

    for _, phase in ipairs({ "state read", "config stage", "detached association", "published state" }) do
        it("retains actual applied bytes after a post-fetch " .. phase .. " / release failure", function()
            local api, manual_state, fetches
            fetches = 0
            api = begin_subs({ strict = true, popen = { { match = "curl ", out = function()
                fetches = fetches + 1
                if phase == "state read" then
                    H.state().failures[SUBS] = { read = true }
                    H.state().failures[sub_lock] = { rmdir = true }
                elseif phase == "config stage" then
                    H.state().failures[CFG .. ".tmp.*"] = { write = true, partial = 5 }
                    H.state().failures[podkop_lock] = { rmdir = true }
                elseif phase == "detached association" then
                    local actor = coroutine.create(function() assert.is_true(api.subscription_detach("main", "0").success) end)
                    local ok, err = coroutine.resume(actor)
                    assert.is_true(ok, tostring(err))
                    assert.equal("dead", coroutine.status(actor))
                    H.state().failures[sub_lock] = { rmdir = true }
                else H.state().failures[podkop_lock] = { rmdir = true } end
                manual_state = H.vfs_read(SUBS)
                return fresh .. "\nPT_CURL_EXIT:0\n"
            end } } })
            H.vfs_write(SUBS, state)
            H.vfs_write(LOG, "old journal\n")
            local response = api.update_all()
            local published = phase == "published state"
            assert.is_false(response.success)
            assert.is_true(response.unknown)
            assert.equal(published, response.applied == true)
            assert.equal(published and 1 or 0, response.updated)
            assert.equal(1, response.failed)
            assert.equal(published, response.restart_required == true)
            assert.is_false(response.restarted)
            assert.matches("cannot release owned lock", response.error)
            if phase == "state read" then assert.matches("Cannot read subscriptions", response.error) end
            if phase == "config stage" then assert.matches("Injected write failure", response.error) end
            if published then
                assert.truthy(H.vfs_read(CFG):find(fresh, 1, true))
                assert.matches("%(manual%)", require("pt-subs-lib").read_subs(SUBS).main[1].last_updated)
            else
                assert.equal(manual_state, H.vfs_read(SUBS), "downloaded data cannot replace current or manually detached state")
                assert.equal(CFG_TEXT, H.vfs_read(CFG))
                assert.falsy(H.vfs_exists(SUBBAK))
            end
            assert.equal("old journal\n", H.vfs_read(LOG))
            assert.equal(1, fetches)
            assert.equal(0, restart_count())
        end)
    end

    for _, log_published in ipairs({ false, true }) do
        it("does not confuse a zero-job journal outcome with applied subscription data (log=" .. tostring(log_published) .. ")", function()
            local api = begin_subs({ strict = true, uci = {} })
            H.vfs_write(SUBS, '{"version":7}')
            H.vfs_write(LOG, "old journal\n")
            local s = require("pt-subs-lib")
            local append = s.append_log
            s.append_log = function(...)
                H.state().failures[sub_lock] = { rmdir = true }
                if not log_published then H.state().failures[LOG] = { read = true } end
                return append(...)
            end
            local response = api.update_all()
            assert.is_false(response.success)
            assert.falsy(response.applied)
            assert.equal(log_published, response.log_applied == true)
            assert.is_true(response.unknown)
            assert.equal(0, response.updated)
            assert.equal('{"version":7}', H.vfs_read(SUBS))
            assert.equal(0, restart_count())
            if not log_published then assert.equal("old journal\n", H.vfs_read(LOG)) end
        end)
    end

    for _, case in ipairs({
        { name = "accepted restart", output = "\nPT_EXIT:0\n", requested = true },
        { name = "failed restart", output = "primary restart diagnostics\nPT_EXIT:7\n", primary = "primary restart diagnostics" },
        { name = "missing exit evidence", output = "missing result marker", primary = "missing result marker" }
    }) do
        it("keeps checked metadata and primary diagnostics after " .. case.name .. " and release failure", function()
            local options = mktemp_world(fresh)
            options.sys = {
                { match = "pidof ", out = "55\nPT_EXIT:0\n" },
                { match = "/etc/init.d/podkop restart", out = function()
                    H.state().failures[podkop_lock] = { rmdir = true }
                    return case.output
                end }
            }
            local api = begin_subs(options)
            H.vfs_write(SUBS, state)
            H.vfs_write("/proc/55/stat", "55 (sing-box) S " .. string.rep("0 ", 18) .. "400\n")
            local response = api.update_all()
            assert.is_false(response.success)
            assert.is_true(response.applied)
            assert.is_true(response.unknown)
            assert.is_false(response.restarted)
            assert.is_true(response.verification_required)
            assert.is_true(response.previous_running)
            assert.is_true(response.previous_identity_known)
            assert.equal("55:400", response.previous_instance)
            assert.equal(case.requested == true, response.restarting == true)
            assert.equal(case.requested ~= true, response.restart_required == true)
            assert.matches("cannot release owned lock", response.details)
            if case.primary then
                assert.equal("Service restart command failed", response.error)
                assert.truthy(response.details:find(case.primary, 1, true))
            end
            assert.truthy(H.vfs_read(CFG):find(fresh, 1, true))
            assert.equal(1, restart_count(), "release failure must never replay a restart")
        end)
    end
end)

describe("subscription network-wait reconciliation", function()
    local state = '{"version":9,"future":{"flag":"keep"},"settings":{"auto_update_interval":4,' ..
        '"auto_update_start":"01:30","auto_update_on_restart":true,"log_display_count":7,"future":"keep"},' ..
        '"main":[{"subscription_url":"https://sub/1","proxy_name":"OldName","future":"entry"}]}'
    local fresh = "vless://fresh@f:443#OldName"

    local function update_interleaved(callback)
        local api, called
        api = begin_subs({ popen = function(command)
            if command:find("curl", 1, true) then
                assert.falsy(called, "only the network request may be retried; this successful fetch runs once")
                called = true
                local actor = coroutine.create(function() callback(api) end)
                local ok, err = coroutine.resume(actor)
                assert.is_true(ok, tostring(err))
                assert.equal("dead", coroutine.status(actor))
                return fresh .. "\nPT_CURL_EXIT:0\n"
            end
            return ""
        end })
        H.vfs_write(SUBS, state)
        local response = api.update_all()
        assert.is_true(called, "the fixture must fetch and execute the competing actor before reconciliation")
        return response
    end

    it("a manual Detach and log Save during fetch both survive, and detached data is skipped", function()
        local response = update_interleaved(function(current)
            assert.is_true(current.subscription_detach("main", "0").success)
            assert.is_true(current.settings_save(nil, nil, nil, "20", true).success)
        end)
        assert.is_true(response.success)
        assert.equal(1, response.skipped)
        assert.equal(0, response.updated)
        assert.equal("skipped", response.outcomes[1].status)
        assert.equal(CFG_TEXT, H.vfs_read(CFG))
        assert.falsy(H.vfs_exists(SUBBAK))
        local data = require("pt-subs-lib").read_subs(SUBS)
        assert.is_nil(data.main[1])
        assert.equal(20, data.settings.log_display_count)
        assert.equal(4, data.settings.auto_update_interval)
        assert.equal("keep", data.settings.future)
        assert.equal(9, data.version)
        assert.same({ flag = "keep" }, data.future)
        assert.equal(0, restart_count())
    end)

    it("updates a still-identical association without reverting a concurrent log Save or unknown fields", function()
        local response = update_interleaved(function(current)
            assert.is_true(current.settings_save(nil, nil, nil, "18", true).success)
        end)
        assert.is_true(response.success)
        assert.equal(1, response.updated)
        local data = require("pt-subs-lib").read_subs(SUBS)
        assert.equal(18, data.settings.log_display_count)
        assert.equal(4, data.settings.auto_update_interval)
        assert.equal("keep", data.settings.future)
        assert.equal("entry", data.main[1].future)
        assert.same({ flag = "keep" }, data.future)
        assert.equal(9, data.version)
        assert.matches("%(manual%)", data.main[1].last_updated)
        assert.equal(1, restart_count())
    end)

    it("keeps a complete Options Save made during fetch while updating the current association", function()
        local response = update_interleaved(function(current)
            assert.is_true(current.settings_save("0", "", false, "16").success)
        end)
        assert.is_true(response.success)
        assert.equal(1, response.updated)
        local data = require("pt-subs-lib").read_subs(SUBS)
        assert.equal(0, data.settings.auto_update_interval)
        assert.equal("", data.settings.auto_update_start)
        assert.is_false(data.settings.auto_update_on_restart)
        assert.equal(16, data.settings.log_display_count)
        assert.equal("keep", data.settings.future)
        assert.equal("entry", data.main[1].future)
    end)

    for _, changed in ipairs({ "url", "name", "type", "link", "removed slot", "moved association" }) do
        it("skips a changed current " .. changed .. " identity instead of applying the fetched snapshot", function()
            local manual_bytes
            local response = update_interleaved(function(current)
                if changed == "url" or changed == "name" then
                    assert.is_true(current.subscription_attach("main", "0", changed == "url" and "https://sub/2" or "https://sub/1",
                        changed == "name" and "ChosenManually" or "OldName", LINK_OLD).success)
                elseif changed == "type" then
                    require("luci.model.uci").cursor():set("podkop", "main", "proxy_config_type", "selector")
                elseif changed == "removed slot" then
                    H.vfs_write(CFG, "config section 'main'\n option connection_type 'proxy'\n option proxy_config_type 'url'\n")
                elseif changed == "moved association" then
                    local s = require("pt-subs-lib")
                    local data = assert(s.read_subs(SUBS))
                    data.main[1], data.main[2] = false, data.main[1]
                    assert.is_true(s.write_subs(data, SUBS))
                else
                    H.vfs_write(CFG, CFG_TEXT:gsub(LINK_OLD:gsub("([^%w])", "%%%1"), function() return LINK_A end))
                end
                manual_bytes = H.vfs_read(SUBS)
            end)
            assert.is_true(response.success)
            assert.equal(1, response.skipped)
            assert.equal(0, response.updated)
            assert.equal(0, response.failed)
            assert.equal(manual_bytes, H.vfs_read(SUBS), "skipping cannot even rewrite the current timestamp/settings")
            assert.falsy(H.vfs_exists(SUBBAK))
            assert.falsy(H.vfs_read(CFG):find(fresh, 1, true))
            assert.equal(0, restart_count())
        end)
    end

    it("fails on a post-fetch state read error without overwriting the concurrently changed bytes", function()
        local response = update_interleaved(function()
            H.vfs_write(SUBS, "concurrently damaged state")
        end)
        assert.is_false(response.success)
        assert.is_string(response.error)
        assert.equal(1, response.failed)
        assert.equal("concurrently damaged state", H.vfs_read(SUBS))
        assert.equal(CFG_TEXT, H.vfs_read(CFG))
        assert.falsy(H.vfs_exists(SUBBAK))
        assert.falsy(H.vfs_exists(LOG))
        assert.equal(0, restart_count())
    end)

    it("visits an association after a null/false slot and preserves that slot index", function()
        local api = begin_subs(mktemp_world("vless://fresh@f:443#b"))
        H.vfs_write(SUBS, '{"version":6,"multi":[null,{"subscription_url":"https://sub/1","proxy_name":"b","future":"keep"}]}')
        local response = api.update_all()
        assert.is_true(response.success)
        assert.equal(1, response.updated)
        assert.equal(1, response.outcomes[1].slot)
        local data = require("pt-subs-lib").read_subs(SUBS)
        assert.is_false(data.multi[1])
        assert.equal("keep", data.multi[2].future)
        assert.equal(6, data.version)
        assert.truthy(H.vfs_read(CFG):find(LINK_A, 1, true))
    end)
end)

describe("subscription backup download", function()
    it("sends exact bytes only after a complete read and close", function()
        local api = begin_subs({ strict = true })
        H.vfs_write(SUBBAK, CFG_TEXT)
        api.download_sub_backup()
        assert.equal("application/octet-stream", H.http()._prepared[1])
        assert.equal(CFG_TEXT, H.body())
        assert.equal('attachment; filename="podkop-sub-backup.conf"', H.http()._headers["Content-Disposition"])
    end)

    for _, operation in ipairs({ "open", "read", "close" }) do
        it("does not send attachment headers or partial bytes on " .. operation .. " failure", function()
            local api = begin_subs({ strict = true, failures = { [SUBBAK] = { [operation] = true, errno = 5 } } })
            H.vfs_write(SUBBAK, CFG_TEXT)
            api.download_sub_backup()
            assert.equal(500, H.http()._status[1].code)
            assert.equal("application/json", H.http()._prepared[1])
            assert.is_string(H.last_json().error)
            assert.is_nil(H.http()._headers["Content-Disposition"])
            assert.falsy(H.body():find(CFG_TEXT, 1, true))
        end)
    end

    it("reports a missing backup explicitly", function()
        local api = begin_subs({ strict = true })
        api.download_sub_backup()
        assert.equal(404, H.http()._status[1].code)
        assert.equal("Sub backup file not found", H.last_json().error)
        assert.is_nil(H.http()._headers["Content-Disposition"])
    end)
end)
