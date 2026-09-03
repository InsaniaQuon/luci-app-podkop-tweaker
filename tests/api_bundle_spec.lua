-- api_bundle_spec | v1.0.0 | 23.08.2026 | Max-coverage specs for V2 pure import handler of api_bundle

package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path

local H = require("pt_harness")
local json = require("pt_json")

local CSS = "/www/luci-static/argon/css/cascade.css"

local PODKOP_CFG = "config podkop 'main'\n\toption enabled '1'\n"
local STUBBY_CFG = "config stubby 'global'\n\toption manual '0'\n"
local FRAG_CFG = "config settings 'settings'\n\toption enabled '1'\n"
local TWEAKER_CFG = "config settings 'settings'\n\toption show_argon_tab '1'\n"
local SB_JSON = '{"outbounds":[]}'

local function begin_bundle(opts)
    opts = opts or {}
    opts.sys = opts.sys or {}
    table.insert(opts.sys, { match = "sing-box check", out = opts.check or "" })
    H.begin(opts)
    local LIB = require("podkop-tweaker.lib")
    LIB.ARGON_CASCADE_CSS = CSS
    if not H.vfs_exists("/etc/config/podkop") then H.vfs_write("/etc/config/podkop", PODKOP_CFG) end
    if not H.vfs_exists("/etc/config/stubby") then H.vfs_write("/etc/config/stubby", STUBBY_CFG) end
    local uci = require("luci.model.uci").cursor()
    uci:set("podkop-tweaker", "settings", "show_argon_tab", "1")
    return H.reload("podkop-tweaker.api_bundle")
end

local function bundle_str(items)
    return json.stringify({
        format = "podkop-tweaker-bundle",
        version = 1,
        created = "2026-08-23 12:00",
        tweaker_version = "4.2.0",
        items = items
    })
end

after_each(function()
    H.finish()
end)

describe("api_bundle.import preconditions", function()
    it("empty content everywhere -> exact error", function()
        local BND = begin_bundle({})
        assert.same({ error = "Bundle content is empty" }, BND.import("", nil, nil))
        assert.same({ error = "Bundle content is empty" }, BND.import("", {}, nil))
    end)

    it("file table and file string fallbacks carry payload", function()
        local BND = begin_bundle({})
        local b = bundle_str({ podkop = { content = PODKOP_CFG } })
        local r1 = BND.import("", { data = b }, nil)
        assert.is_true(r1.results.podkop.ok)
        H.finish()
        local BND2 = begin_bundle({})
        local r2 = BND2.import("", b, nil)
        assert.is_true(r2.results.podkop.ok)
    end)

    it("oversize content rejected", function()
        local BND = begin_bundle({})
        assert.same({ error = "Bundle too large (max 4MB)" },
            BND.import(string.rep("x", 4194305), nil, nil))
    end)

    it("null bytes rejected", function()
        local BND = begin_bundle({})
        assert.same({ error = "Invalid content: contains null bytes" },
            BND.import("a\0b", nil, nil))
    end)

    it("garbage json and wrong format rejected identically", function()
        local BND = begin_bundle({})
        assert.same({ error = "Not a valid Podkop Tweaker bundle" }, BND.import("zz", nil, nil))
        assert.same({ error = "Not a valid Podkop Tweaker bundle" },
            BND.import(json.stringify({ format = "other", version = 1, items = {} }), nil, nil))
    end)

    it("version gates", function()
        local BND = begin_bundle({})
        local v0 = json.stringify({ format = "podkop-tweaker-bundle", version = 0, items = { podkop = {} } })
        local v2 = json.stringify({ format = "podkop-tweaker-bundle", version = 2, items = { podkop = {} } })
        assert.same({ error = "Unsupported bundle version: 0" }, BND.import(v0, nil, nil))
        assert.same({ error = "Unsupported bundle version: 2" }, BND.import(v2, nil, nil))
    end)

    it("empty items rejected", function()
        local BND = begin_bundle({})
        assert.same({ error = "Bundle has no items" },
            BND.import(bundle_str({}), nil, nil))
    end)
end)

describe("api_bundle.import application", function()
    it("unknown item lands in skipped, known applied", function()
        local BND = begin_bundle({})
        local r = BND.import(bundle_str({
            bogus = { x = 1 },
            fragment = { content = FRAG_CFG }
        }), nil, nil)
        assert.is_true(r.success)
        assert.falsy(r.results.bogus)
        assert.is_true(r.results.fragment.ok)
        assert.same({ "bogus" }, r.skipped)
        assert.equal(FRAG_CFG, H.vfs_read("/etc/config/podkop-fragment"))
        assert.falsy(r.restarting)
        assert.equal(0, #H.exec_cmds())
    end)

    it("selection filters application; unselected goes to skipped", function()
        local BND = begin_bundle({})
        local r = BND.import(bundle_str({
            podkop = { content = PODKOP_CFG },
            stubby = { content = STUBBY_CFG }
        }), nil, "podkop")
        assert.is_true(r.results.podkop.ok)
        assert.falsy(r.results.stubby)
        assert.same({ "stubby" }, r.skipped)
        assert.is_true(r.restarting)
        local stubby_restarts = 0
        for _, c in ipairs(H.exec_cmds()) do
            if c:find("^/etc/init%.d/stubby restart") then stubby_restarts = stubby_restarts + 1 end
        end
        assert.equal(0, stubby_restarts)
        assert.equal(1, #H.exec_cmds())
    end)

    it("full happy import: files, subs data, three service restarts", function()
        local BND = begin_bundle({})
        H.vfs_write(CSS, ".base{}\n")
        local r = BND.import(bundle_str({
            podkop = { content = PODKOP_CFG },
            stubby = { content = STUBBY_CFG },
            singbox = { content = SB_JSON },
            fragment = { content = FRAG_CFG },
            tweaker = { content = TWEAKER_CFG },
            argon = { settings = { font_size = "16", font_family = "Google Sans" } },
            subs = { data = { main = {
                { subscription_url = "https://sub/1", proxy_name = "N", last_updated = "x" }
            } } }
        }), nil, nil)
        assert.is_true(r.success)
        for _, name in ipairs({ "podkop", "stubby", "singbox", "fragment", "tweaker", "argon", "subs" }) do
            assert.is_true(r.results[name].ok, name)
        end
        assert.same({}, r.skipped)
        assert.is_true(r.restarting)
        local function has_restart(name)
            for _, c in ipairs(H.exec_cmds()) do
                if c:find("/etc/init.d/" .. name .. " restart", 1, true) then return true end
            end
            return false
        end
        assert.truthy(has_restart("podkop"))
        assert.truthy(has_restart("stubby"))
        assert.truthy(has_restart("sing-box"))
        assert.truthy(H.vfs_read("/etc/config/podkop-fragment"):find("enabled '1'"))
        assert.truthy(H.vfs_read(CSS):find("font%-size: 16px"))
        local subs = require("pt-subs-lib").read_subs("/etc/config/podkop-tweaker-subs.json")
        -- read_subs strips the version key; verify it in the raw file instead
        assert.truthy(H.vfs_read("/etc/config/podkop-tweaker-subs.json"):find('"version":1', 1, true))
        assert.equal("https://sub/1", subs.main[1].subscription_url)
    end)

    it("partial failure keeps success true via any_ok", function()
        local BND = begin_bundle({})
        local r = BND.import(bundle_str({
            podkop = { content = "invalid uci garbage" },
            stubby = { content = STUBBY_CFG }
        }), nil, nil)
        assert.is_false(r.results.podkop.ok)
        assert.matches("Invalid UCI format", r.results.podkop.error)
        assert.is_true(r.results.stubby.ok)
        assert.is_true(r.success)
        assert.same({}, r.skipped)
    end)

    it("disabled argon tab surfaces per-item error", function()
        local BND = begin_bundle({})
        local uci = require("luci.model.uci").cursor()
        uci:set("podkop-tweaker", "settings", "show_argon_tab", "0")
        local r = BND.import(bundle_str({
            argon = { settings = { font_size = "16" } }
        }), nil, nil)
        assert.is_false(r.success)
        assert.is_false(r.results.argon.ok)
        assert.equal("Argon tab is disabled", r.results.argon.error)
    end)

    it("invalid subs section data -> per-item validation error", function()
        local BND = begin_bundle({})
        local r = BND.import(bundle_str({
            subs = { data = { main = "not-a-table" } }
        }), nil, nil)
        assert.is_false(r.results.subs.ok)
        assert.matches("Invalid section data", r.results.subs.error)
    end)

    it("json null mid-array keeps later slots (M2)", function()
        local BND = begin_bundle({})
        -- hand-built JSON: [ {sub1}, null, {sub3} ] — null decodes to a sparse hole,
        -- ipairs would silently drop slot 3
        local raw = '{"format":"podkop-tweaker-bundle","version":1,' ..
            '"created":"t","tweaker_version":"4.2.0",' ..
            '"items":{"subs":{"data":{"main":[' ..
            '{"subscription_url":"https://sub/1","proxy_name":"A"},' ..
            'null,' ..
            '{"subscription_url":"https://sub/3","proxy_name":"C"}' ..
            ']}}}}'
        local r = BND.import(raw, nil, nil)
        assert.is_true(r.results.subs.ok, r.results.subs and r.results.subs.error)
        local subs = require("pt-subs-lib").read_subs("/etc/config/podkop-tweaker-subs.json")
        assert.equal("https://sub/1", subs.main[1].subscription_url)
        assert.equal(false, subs.main[2])
        assert.equal("https://sub/3", subs.main[3].subscription_url)
    end)

    it("subs settings interval normalized, no fractional cron hours (m4)", function()
        local BND = begin_bundle({})
        local r = BND.import(bundle_str({
            subs = { data = {
                main = { { subscription_url = "https://sub/1", proxy_name = "A" } },
                settings = {
                    auto_update_interval = 0.5,
                    auto_update_start = "01:30",
                    auto_update_on_restart = true,
                    log_display_count = 99
                }
            } }
        }), nil, nil)
        assert.is_true(r.results.subs.ok, r.results.subs and r.results.subs.error)
        for _, c in ipairs(H.exec_cmds()) do
            if c:find("crontab", 1, true) then
                assert.falsy(c:find("%d%.%d"), "fractional hour in crontab: " .. c)
            end
        end
        local raw_subs = H.vfs_read("/etc/config/podkop-tweaker-subs.json")
        assert.falsy(raw_subs:find("99"), "log_display_count not clamped")
    end)

    it("non-table known item lands in skipped (m3)", function()
        local BND = begin_bundle({})
        local r = BND.import(bundle_str({
            podkop = "just-a-string"
        }), nil, nil)
        assert.same({ "podkop" }, r.skipped)
        assert.falsy(r.results.podkop)
        assert.is_false(r.success)
        assert.equal(PODKOP_CFG, H.vfs_read("/etc/config/podkop"))
    end)

    it("sing-box check failure inside item -> detailed error", function()
        local BND = begin_bundle({ check = "bad json\n" })
        local r = BND.import(bundle_str({
            singbox = { content = '{"broken":}' }
        }), nil, nil)
        assert.is_false(r.results.singbox.ok)
        assert.matches("sing%-box check failed", r.results.singbox.error)
        assert.is_false(r.success)
    end)
end)
