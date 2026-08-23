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

local function begin_subs(opts)
    opts = opts or {}
    opts.uci = opts.uci or UCI_SEED
    H.begin(opts)
    if not H.vfs_exists(CFG) then H.vfs_write(CFG, CFG_TEXT) end
    return H.reload("podkop-tweaker.api_subs")
end

local function mktemp_world(payload)
    return {
        sys = { { match = "mktemp", out = "/tmp/pt-fixed\n" } },
        popen = function(cmd)
            if cmd:find("^mktemp") then return "/tmp/pt-fixed\n" end
            return ""
        end
    }, payload
end

after_each(function()
    H.finish()
end)

describe("api_subs.subscription_state", function()
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
        assert.falsy(H.vfs_exists("/tmp/pt-fixed"))
    end)

    it("base64 payload decoded", function()
        local SUB = begin_fetch(b64("vmess://xyz@h:8443#Vm\n"))
        local r = SUB.subscription_fetch("https://sub.example/x")
        assert.is_true(r.success)
        assert.is_false(r.http_warning)
        assert.equal("Vm", r.proxies[1].name)
        assert.equal("VMESS", r.proxies[1].protocol)
    end)

    it("mktemp failure -> download error", function()
        local SUB = begin_subs({ sys = { { match = "mktemp", out = "" } } })
        assert.same({ error = "Failed to download subscription" },
            SUB.subscription_fetch("https://sub.example/x"))
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
        local nohups = 0
        for _, c in ipairs(H.exec_cmds()) do
            if c:find("nohup", 1, true) then nohups = nohups + 1 end
        end
        assert.equal(0, nohups)
        local subs = require("pt-subs-lib").read_subs(SUBS)
        assert.equal("https://sub/1", subs.main[1].subscription_url)
        assert.matches("%(manual%)", subs.main[1].last_updated)
        local log = H.vfs_read(LOG)
        assert.truthy(log:find("unchanged=1", 1, true))
        assert.truthy(log:find("OldName: unchanged", 1, true))
    end)

    it("unchanged write failure -> exact error", function()
        local SUB = begin_subs({})
        local S = require("pt-subs-lib")
        S.write_subs = function() return false end
        assert.same({ error = "Failed to save data" },
            SUB.subscription_attach("main", "0", "https://sub/1", "OldName", LINK_OLD))
    end)

    it("changed link on url section: backup, replace, subs, nohup restart, log", function()
        local SUB = begin_subs({})
        local new_link = "vless://new@n:443#NewName"
        local r = SUB.subscription_attach("main", "0", "https://sub/2", "NewName", new_link)
        assert.same({ success = true, restarting = true }, r)
        local cfg = H.vfs_read(CFG)
        assert.truthy(cfg:find("proxy_string '" .. new_link .. "'", 1, true))
        assert.falsy(cfg:find(LINK_OLD, 1, true))
        assert.equal(CFG_TEXT, H.vfs_read(SUBBAK))
        assert.truthy(H.exec_cmds()[1]:find("^nohup /etc/init%.d/podkop restart"))
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
        local SUB = begin_subs({})
        local S = require("pt-subs-lib")
        S.write_subs = function() return false end
        assert.same({ error = "Failed to save data" },
            SUB.subscription_attach("main", "0", "https://s", "p", "vless://z@z:1#z"))
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
        assert.same({ success = true }, SUB.settings_save("0", "01:30", false, "100"))
        local st = read_subs_json().settings
        assert.equal(0, st.auto_update_interval)
        assert.equal("", st.auto_update_start)
        assert.equal(false, st.auto_update_on_restart)
        assert.equal(25, st.log_display_count)
        assert.truthy(H.vfs_exists("/usr/bin/pt-auto-update"))
        local cleanup = false
        local rmhot = false
        for _, c in ipairs(H.exec_cmds()) do
            if c:find("grep -v pt-auto-update", 1, true) then cleanup = true end
        end
        for _, c in ipairs(H.execute_cmds()) do
            if c:find("rm -f /etc/hotplug.d/iface/99-pt-subs", 1, true) then rmhot = true end
        end
        assert.truthy(cleanup)
        assert.truthy(rmhot)
        -- actual file removal is shell territory (os.execute stubbed); command log above is the contract
    end)

    it("valid interval: cron hours computed, hotplug written when enabled", function()
        local SUB = begin_subs({})
        assert.same({ success = true }, SUB.settings_save("4", "01:30", true, "5"))
        local st = read_subs_json().settings
        assert.equal(4, st.auto_update_interval)
        assert.equal("01:30", st.auto_update_start)
        assert.equal(5, st.log_display_count)
        local cron_line = nil
        for _, c in ipairs(H.exec_cmds()) do
            local m = c:match("echo '(%d+ %d+[%d,]*) %* %* %* /usr/bin/pt%-auto%-update'")
            if m then cron_line = m end
        end
        assert.equal("30 1,5,9,13,17,21", cron_line)
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
end)

describe("api_subs.update_all", function()
    local SUB_ENTRY = '{"main":[{"subscription_url":"https://sub/1","proxy_name":"OldName"}]}'

    it("updated: real pipeline replaces link, restarts, logs", function()
        local SUB = begin_subs(mktemp_world(nil))
        H.vfs_write(SUBS, SUB_ENTRY)
        H.vfs_write("/tmp/pt-fixed", "vless://fresh@f:443#OldName\n")
        local r = SUB.update_all()
        assert.same({ success = true, updated = 1, unchanged = 0, failed = 0, restarted = true }, r)
        assert.truthy(H.vfs_read(CFG):find("vless://fresh@f:443#OldName", 1, true))
        assert.truthy(H.exec_cmds()[1]:find("^nohup /etc/init%.d/podkop restart"))
        assert.truthy(H.vfs_read(LOG):find("updated=1", 1, true))
        local subs = require("pt-subs-lib").read_subs(SUBS)
        assert.matches("%(manual%)", subs.main[1].last_updated)
    end)

    it("unchanged: same link -> no restart", function()
        local SUB = begin_subs(mktemp_world(nil))
        H.vfs_write(SUBS, SUB_ENTRY)
        H.vfs_write("/tmp/pt-fixed", LINK_OLD .. "\n")
        local r = SUB.update_all()
        assert.same({ success = true, updated = 0, unchanged = 1, failed = 0, restarted = false }, r)
        assert.equal(0, #H.exec_cmds())
    end)

    it("failed: garbage payload retries then reports", function()
        local SUB = begin_subs(mktemp_world(nil))
        H.vfs_write(SUBS, SUB_ENTRY)
        H.vfs_write("/tmp/pt-fixed", "garbage\n")
        local r = SUB.update_all()
        assert.same({ success = true, updated = 0, unchanged = 0, failed = 1, restarted = false }, r)
        local sleeps = 0
        for _, c in ipairs(H.execute_cmds()) do
            if c:find("^sleep 10") then sleeps = sleeps + 1 end
        end
        assert.equal(2, sleeps)
        assert.truthy(H.vfs_read(LOG):find("failed", 1, true))
    end)
end)
