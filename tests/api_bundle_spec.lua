-- Bundle contracts: per-item application, strict exports and checked finishing.

package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path

local H = require("pt_harness")
local json = require("pt_json")

local CSS = "/www/luci-static/argon/css/cascade.css"

local PODKOP_CFG = "config podkop 'main'\n\toption enabled '1'\n"
local STUBBY_CFG = "config stubby 'global'\n\toption manual '0'\n"
local FRAG_CFG = "config settings 'settings'\n\toption enabled '1'\n"
local TWEAKER_CFG = "config settings 'settings'\n\toption show_argon_tab '1'\n"
local SB_JSON = '{"outbounds":[]}'
local SUBS = "/etc/config/podkop-tweaker-subs.json"

local function restart_count(name)
    local count = 0
    for _, commands in ipairs({ H.exec_cmds(), H.popen_cmds() }) do
        for _, command in ipairs(commands) do
            if command:find("/etc/init.d/" .. name .. " restart", 1, true) then count = count + 1 end
        end
    end
    return count
end

local function begin_bundle(opts)
    opts = opts or {}
    if opts.strict == nil then opts.strict = true end
    opts.sys = opts.sys or {}
    table.insert(opts.sys, { match = "sing-box check", out = (opts.check or "") .. "\nPT_EXIT:" .. (opts.check and "1" or "0") .. "\n" })
    table.insert(opts.sys, { match = function(command)
        return command:find("pidof ", 1, true) and command:find("PT_EXIT:", 1, true)
    end, out = "\nPT_EXIT:1\n" })
    table.insert(opts.sys, { match = function(command)
        return command:find("/etc/init.d/", 1, true) and command:find(" restart", 1, true) and command:find("PT_EXIT:", 1, true)
    end, out = "\nPT_EXIT:0\n" })
    table.insert(opts.sys, { match = "crontab ", out = "\nPT_EXIT:0\n" })
    table.insert(opts.sys, { match = "mkdir -p /etc/hotplug.d/iface", out = "\nPT_EXIT:0\n" })
    if opts.popen == nil then opts.popen = opts.sys end
    H.begin(opts)
    local LIB = require("podkop-tweaker.lib")
    LIB.ARGON_CASCADE_CSS = CSS
    if not H.vfs_exists("/etc/config/podkop") then H.vfs_write("/etc/config/podkop", PODKOP_CFG) end
    if not H.vfs_exists("/etc/config/stubby") then H.vfs_write("/etc/config/stubby", STUBBY_CFG) end
    local uci = require("luci.model.uci").cursor()
    uci:set("podkop-tweaker", "settings", "settings")
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
    it("wrong nested content types are per-item errors and earlier valid items still restart", function()
        local BND = begin_bundle({})
        local r = BND.import(bundle_str({ podkop = { content = PODKOP_CFG }, stubby = { content = 42 }, tweaker = { content = {} } }), nil, nil)
        assert.is_true(r.results.podkop.ok)
        assert.is_false(r.results.stubby.ok)
        assert.is_false(r.results.tweaker.ok)
        assert.equal("Item content must be text", r.results.stubby.error)
        assert.is_true(r.restarting)
        assert.equal(STUBBY_CFG, H.vfs_read("/etc/config/stubby"))
    end)
    it("isolates unexpected item exceptions without losing previous restart flags", function()
        local BND = begin_bundle({})
        local logic = require("podkop-tweaker.bundle")
        local apply = logic.apply_item
        logic.apply_item = function(name, item, env)
            if name == "stubby" then error("synthetic failure") end
            return apply(name, item, env)
        end
        local r = BND.import(bundle_str({ podkop = { content = PODKOP_CFG }, stubby = { content = STUBBY_CFG }, fragment = { content = FRAG_CFG } }), nil, nil)
        assert.is_true(r.results.podkop.ok)
        assert.is_false(r.results.stubby.ok)
        assert.is_true(r.results.fragment.ok)
        assert.is_true(r.restarting)
    end)
    it("round-trips false and null slots without losing later associations", function()
        local BND = begin_bundle({})
        local input = bundle_str({ subs = { data = { main = { false, { subscription_url = "https://sub/2", proxy_name = "second" }, false } } } })
        assert.is_true(BND.import(input, nil, nil).results.subs.ok)
        local data = require("pt-subs-lib").read_subs("/etc/config/podkop-tweaker-subs.json")
        assert.is_false(data.main[1])
        assert.equal("second", data.main[2].proxy_name)
        assert.is_false(data.main[3])
        assert.is_true(BND.import(bundle_str({ subs = { data = data } }), nil, nil).results.subs.ok)
    end)
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
        assert.equal(0, restart_count("podkop"))
        assert.equal(0, restart_count("stubby"))
        assert.equal(0, restart_count("sing-box"))
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
        assert.equal(0, restart_count("stubby"))
        assert.equal(1, restart_count("podkop"))
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
        assert.equal(1, restart_count("podkop"))
        assert.equal(1, restart_count("stubby"))
        assert.equal(1, restart_count("sing-box"))
        assert.truthy(H.vfs_read("/etc/config/podkop-fragment"):find("enabled '1'"))
        assert.truthy(H.vfs_read(CSS):find("font%-size: 16px"))
        local subs = require("pt-subs-lib").read_subs("/etc/config/podkop-tweaker-subs.json")
        -- State version metadata is preserved by the strict read/write contract.
        assert.truthy(H.vfs_read("/etc/config/podkop-tweaker-subs.json"):find('"version":1', 1, true))
        assert.equal(1, subs.version)
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

    it("disabled argon tab: argon item silently skipped, not an error", function()
        local BND = begin_bundle({})
        local uci = require("luci.model.uci").cursor()
        uci:set("podkop-tweaker", "settings", "show_argon_tab", "0")
        H.vfs_write(CSS, ".base{}\n")
        local r = BND.import(bundle_str({
            argon = { settings = { font_size = "16" } }
        }), nil, nil)
        -- no per-item failure: the item is ignored (invisible settings)
        assert.falsy(r.results.argon)
        assert.same({ "argon" }, r.skipped)
        assert.is_false(r.success)
        -- uci typography untouched
        assert.is_nil(uci:get("argon", "typography", "font_size"))
        -- css not injected
        assert.falsy(H.vfs_read(CSS):find("Podkop Tweaker Typography", 1, true))
    end)

    it("invalid positional subs data -> per-item validation error", function()
        local BND = begin_bundle({})
        local r = BND.import(bundle_str({
            subs = { data = { main = { false, "not-a-slot" } } }
        }), nil, nil)
        assert.is_false(r.results.subs.ok)
        assert.matches("Invalid slot data", r.results.subs.error)
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
        assert.is_true(BND.import(bundle_str({ subs = { data = subs } }), nil, nil).results.subs.ok)
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
        for _, commands in ipairs({ H.exec_cmds(), H.popen_cmds() }) do
            for _, c in ipairs(commands) do
                if c:find("crontab", 1, true) then
                    assert.falsy(c:find("%d%.%d"), "fractional hour in crontab: " .. c)
                end
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

local function begin_export(items, opts)
    opts = opts or {}
    opts.fv = { items = items }
    local api = begin_bundle(opts)
    local run = { handles = {}, writes = {}, before = {} }
    local open = io.open
    io.open = function(path, mode)
        local fd, err, errno = open(path, mode)
        if fd then run.handles[#run.handles + 1] = fd end
        return fd, err, errno
    end
    local http = H.http()
    local prepare, header, write = http.prepare_content, http.header, http.write
    local function assert_closed()
        for _, fd in ipairs(run.handles) do assert.is_true(fd._closed, "bundle attachment started before a selected read was closed") end
    end
    http.prepare_content = function(kind)
        if kind == "application/octet-stream" then assert_closed() end
        return prepare(kind)
    end
    http.header = function(key, value)
        if key == "Content-Disposition" then assert_closed() end
        return header(key, value)
    end
    http.write = function(value)
        assert.equal("string", type(value))
        assert_closed()
        run.writes[#run.writes + 1] = value
        return write(value)
    end
    function run.export()
        for path, entry in pairs(H.state().vfs) do run.before[path] = entry.content end
        api.export()
        local after = {}
        for path, entry in pairs(H.state().vfs) do after[path] = entry.content end
        assert.same(run.before, after, "export must not repair or change selected data")
        for _, fd in ipairs(run.handles) do assert.is_true(fd._closed) end
        assert.equal("no-cache, no-store, must-revalidate", http._headers["Cache-Control"])
        assert.equal("no-cache", http._headers.Pragma)
        assert.equal("0", http._headers.Expires)
    end
    return run
end

local function export_failure(run, code, component)
    run.export()
    assert.equal(code, H.http()._status[1] and H.http()._status[1].code or 200)
    assert.same({ "application/json" }, H.http()._prepared)
    assert.is_nil(H.http()._headers["Content-Disposition"])
    assert.same({}, run.writes, "selected read failures must never produce a partial or empty normal attachment")
    local result = H.last_json()
    assert.is_table(result)
    assert.equal("string", type(result.error))
    assert.same(result, json.parse(H.body()))
    if component then
        assert.is_table(result.errors[component])
        assert.equal(code, result.errors[component].status)
        assert.truthy(result.details:find(component, 1, true))
        assert.truthy(result.details:find("deselect", 1, true))
    end
    return result
end

local function export_attachment(run)
    run.export()
    assert.same({}, H.http()._status)
    assert.same({ "application/octet-stream" }, H.http()._prepared)
    assert.equal('attachment; filename="' .. os.date("%d.%m.%Y") .. '-podkop-tweaker-bundle-backup.json"',
        H.http()._headers["Content-Disposition"])
    assert.equal(1, #run.writes)
    assert.is_nil(H.last_json())
    local result = json.parse(H.body())
    assert.equal("podkop-tweaker-bundle", result.format)
    assert.equal(1, result.version)
    return result
end

describe("api_bundle.export selected component integrity", function()
    it("returns exact selected bytes in the compatible v1 format", function()
        local run = begin_export("podkop,stubby,singbox,fragment,tweaker,subs")
        H.vfs_write("/etc/sing-box/config.json", SB_JSON)
        H.vfs_write("/etc/config/podkop-fragment", FRAG_CFG)
        H.vfs_write("/etc/config/podkop-tweaker", TWEAKER_CFG)
        H.vfs_write(SUBS, '{"version":7,"future":"keep","main":[false,{"subscription_url":"https://sub/2","future":true}]}')
        local result = export_attachment(run)
        assert.equal(PODKOP_CFG, result.items.podkop.content)
        assert.equal(STUBBY_CFG, result.items.stubby.content)
        assert.equal(SB_JSON, result.items.singbox.content)
        assert.equal(FRAG_CFG, result.items.fragment.content)
        assert.equal(TWEAKER_CFG, result.items.tweaker.content)
        assert.equal(7, result.items.subs.data.version)
        assert.equal("keep", result.items.subs.data.future)
        assert.is_false(result.items.subs.data.main[1])
        assert.is_true(result.items.subs.data.main[2].future)
        assert.is_nil(result.omitted)
    end)

    for _, component in ipairs({
        { name = "podkop", path = "/etc/config/podkop", content = PODKOP_CFG },
        { name = "stubby", path = "/etc/config/stubby", content = STUBBY_CFG },
        { name = "singbox", path = "/etc/sing-box/config.json", content = SB_JSON },
        { name = "fragment", path = "/etc/config/podkop-fragment", content = FRAG_CFG },
        { name = "tweaker", path = "/etc/config/podkop-tweaker", content = TWEAKER_CFG }
    }) do
        for _, case in ipairs({
            { label = "open", failure = { open = true, errno = 13 } },
            { label = "read", failure = { read = true } },
            { label = "close", failure = { close = true } }
        }) do
            it("reports selected " .. component.name .. " " .. case.label .. " failure instead of exporting other items silently", function()
                local run = begin_export("podkop,subs," .. component.name, { failures = { [component.path] = case.failure } })
                H.vfs_write(component.path, component.content)
                local result = export_failure(run, 500, component.name)
                assert.equal(component.path, result.errors[component.name].path)
                assert.is_nil(result.items)
                assert.falsy(result.omitted and result.omitted[component.name])
            end)
        end
    end

    it("treats an absent required Podkop config as HTTP 404, not an optional omission", function()
        local run = begin_export("podkop,subs")
        H.state().vfs["/etc/config/podkop"] = nil
        export_failure(run, 404, "podkop")
    end)

    it("reports every selected failure and gives IO failure priority over a missing component", function()
        local run = begin_export("podkop,stubby,subs", { failures = { ["/etc/config/stubby"] = { close = true } } })
        H.state().vfs["/etc/config/podkop"] = nil
        local result = export_failure(run, 500)
        assert.equal(404, result.errors.podkop.status)
        assert.equal(500, result.errors.stubby.status)
        assert.truthy(result.details:find("/etc/config/podkop", 1, true))
        assert.truthy(result.details:find("/etc/config/stubby", 1, true))
        assert.is_nil(result.items)
    end)

    it("records only genuinely absent optional components in additive omitted metadata", function()
        local run = begin_export("podkop,stubby,singbox,fragment,tweaker")
        H.state().vfs["/etc/config/stubby"] = nil
        local result = export_attachment(run)
        assert.same({ podkop = { content = PODKOP_CFG } }, result.items)
        for name, path in pairs({ stubby = "/etc/config/stubby", singbox = "/etc/sing-box/config.json",
            fragment = "/etc/config/podkop-fragment", tweaker = "/etc/config/podkop-tweaker" }) do
            assert.same({ reason = "not_found", path = path, optional = true }, result.omitted[name])
        end
    end)

    it("does not emit an empty backup attachment when only absent optional items were selected", function()
        local run = begin_export("fragment,singbox")
        local result = export_failure(run, 404)
        assert.equal("not_found", result.omitted.fragment.reason)
        assert.equal("not_found", result.omitted.singbox.reason)
    end)

    it("reports an existing empty optional component as a failure", function()
        local run = begin_export("podkop,fragment")
        H.vfs_write("/etc/config/podkop-fragment", " \r\n\t")
        assert.matches("empty", export_failure(run, 500, "fragment").errors.fragment.error)
    end)

    for _, content in ipairs({ "", "not json", "[]", "false" }) do
        it("refuses failed/invalid existing subscription state instead of exporting it as an empty object: " .. content, function()
            local run = begin_export("podkop,subs")
            H.vfs_write(SUBS, content)
            export_failure(run, 500, "subs")
        end)
    end

    for _, case in ipairs({ { open = true, errno = 5 }, { read = true }, { close = true } }) do
        it("refuses subscription IO failures without falling back to empty state", function()
            local run = begin_export("podkop,subs", { failures = { [SUBS] = case } })
            H.vfs_write(SUBS, '{"version":1,"future":"keep"}')
            export_failure(run, 500, "subs")
        end)
    end

    it("exports a missing first-run subscriptions file as legitimate empty state", function()
        local run = begin_export("subs")
        assert.same({}, export_attachment(run).items.subs.data)
        assert.falsy(H.vfs_exists(SUBS))
    end)

    it("exports an explicitly empty subscriptions object as legitimate state", function()
        local run = begin_export("subs")
        H.vfs_write(SUBS, "{}")
        assert.same({}, export_attachment(run).items.subs.data)
    end)

    it("keeps hidden Argon intentionally invisible without calling its settings reader", function()
        local run = begin_export("podkop,argon")
        require("luci.model.uci").cursor():set("podkop-tweaker", "settings", "show_argon_tab", "0")
        require("podkop-tweaker.argon").read_settings = function() error("hidden typography must not be read") end
        local result = export_attachment(run)
        assert.is_nil(result.items.argon)
        assert.is_nil(result.omitted)
    end)

    it("fails a visible Argon read rather than exporting default-filled typography", function()
        local run = begin_export("podkop,argon")
        require("podkop-tweaker.argon").read_settings = function() return nil, "native UCI read failed" end
        assert.equal("native UCI read failed", export_failure(run, 500, "argon").errors.argon.details)
    end)

    it("does not treat a typography error object as exportable settings", function()
        local run = begin_export("podkop,argon")
        require("podkop-tweaker.argon").read_settings = function() return { error = "bad UCI" } end
        export_failure(run, 500, "argon")
    end)

    it("reports bounded selected-file overflow without an attachment", function()
        local run = begin_export("podkop,fragment")
        H.vfs_write("/etc/config/podkop-fragment", string.rep("x", 1048577))
        assert.matches("size limit", export_failure(run, 500, "fragment").errors.fragment.details)
    end)

    it("refuses serialized bundles larger than the existing import cap", function()
        local run = begin_export("podkop,stubby,fragment,tweaker")
        local prefix = "config settings 'settings'\n#"
        local text = prefix .. string.rep("x", 1048576 - #prefix)
        for _, path in ipairs({ "/etc/config/podkop", "/etc/config/stubby", "/etc/config/podkop-fragment", "/etc/config/podkop-tweaker" }) do
            H.vfs_write(path, text)
        end
        assert.matches("import limit", export_failure(run, 500).details)
    end)
end)

describe("api_bundle.import disk and finishing outcomes", function()
    it("uses the shared service applier with restart disabled for all three service items", function()
        begin_bundle({})
        local srv = require("podkop-tweaker.services")
        local calls = {}
        srv.apply_service = function(name, content, options)
            calls[#calls + 1] = { name, content, options }
            return { success = true, applied = true, warning = "backup retained" }
        end
        srv.restart_service = function() error("per-item application must defer restarts") end
        local logic = require("podkop-tweaker.bundle")
        local env = {}
        for _, item in ipairs({ { "podkop", PODKOP_CFG }, { "stubby", STUBBY_CFG }, { "singbox", SB_JSON } }) do
            local ok, err, info = logic.apply_item(item[1], { content = item[2] }, env)
            assert.is_true(ok, err)
            assert.is_true(info.applied)
            assert.equal("backup retained", info.warning)
            assert.is_true(env["restart_" .. item[1]])
        end
        assert.same({ { "podkop", PODKOP_CFG, { restart = false } }, { "stubby", STUBBY_CFG, { restart = false } },
            { "singbox", SB_JSON, { restart = false } } }, calls)
    end)

    for _, service in ipairs({
        { name = "podkop", init = "podkop", path = "/etc/config/podkop", before = PODKOP_CFG,
            content = "config podkop 'main'\n option enabled '0'\n" },
        { name = "stubby", init = "stubby", path = "/etc/config/stubby", before = STUBBY_CFG,
            content = "config stubby 'global'\n option manual '1'\n" },
        { name = "singbox", init = "sing-box", path = "/etc/sing-box/config.json", before = SB_JSON,
            content = '{"outbounds":[{"type":"direct","tag":"direct"}]}' }
    }) do
        it("reports disk-applied " .. service.name .. " with a checked restart failure, never no changes", function()
            local details = "restart hook failed\nsecond diagnostic line\n"
            local api = begin_bundle({ sys = { { match = "/etc/init.d/" .. service.init .. " restart", out = details .. "\nPT_EXIT:9\n" } } })
            H.vfs_write(service.path, service.before)
            local result = api.import(bundle_str({ [service.name] = { content = service.content } }), nil, nil)
            local item = result.results[service.name]
            assert.is_false(item.ok)
            assert.is_true(item.applied)
            assert.is_true(item.partial)
            assert.is_true(item.restart_required)
            assert.matches("Configuration saved, but", item.error)
            assert.truthy(item.details:find("second diagnostic line", 1, true))
            assert.is_false(result.success)
            assert.is_true(result.applied)
            assert.is_true(result.partial)
            assert.is_false(result.complete)
            assert.is_false(result.restarting)
            assert.equal(service.content, H.vfs_read(service.path))
            assert.equal(service.before, H.vfs_read(service.path .. ".auto-backup"))
            assert.equal(1, restart_count(service.init), "failed mutation/restart must not be replayed")
            assert.is_false(result.restarts[service.name].success)
        end)
    end

    it("continues independent checked restarts and keeps a failed item's full scoped result", function()
        local api = begin_bundle({ sys = { { match = "/etc/init.d/stubby restart", out = "stubby failed\nPT_EXIT:4\n" } } })
        local result = api.import(bundle_str({ podkop = { content = PODKOP_CFG }, stubby = { content = STUBBY_CFG },
            singbox = { content = SB_JSON } }), nil, nil)
        assert.is_true(result.success)
        assert.is_true(result.partial)
        assert.is_false(result.complete)
        assert.is_false(result.results.stubby.ok)
        assert.is_true(result.results.stubby.applied)
        assert.is_true(result.results.podkop.ok)
        assert.is_true(result.results.singbox.ok)
        for _, init in ipairs({ "podkop", "stubby", "sing-box" }) do assert.equal(1, restart_count(init)) end
    end)

    it("forwards restart evidence without claiming process readiness", function()
        local api = begin_bundle({})
        local evidence = { success = true, restarting = true, verification_required = true,
            previous_running = true, previous_instance = "321:9876", previous_identity_known = true }
        require("podkop-tweaker.services").restart_service = function(name)
            assert.equal("podkop", name)
            return evidence
        end
        local result = api.import(bundle_str({ podkop = { content = PODKOP_CFG } }), nil, nil)
        assert.is_true(result.restarting)
        assert.is_true(result.verification_required)
        assert.is_true(result.previous_running)
        assert.equal("321:9876", result.previous_instance)
        assert.is_true(result.previous_identity_known)
        assert.same(evidence, result.results.podkop.restart)
        assert.is_nil(result.ready)
    end)

    it("retains applied service metadata if publication succeeded but the applier reports an error", function()
        local api = begin_bundle({})
        local srv = require("podkop-tweaker.services")
        srv.apply_service = function() return { success = false, applied = true, error = "Cannot release service lock", details = "inspect lock" } end
        srv.restart_service = function() error("a failed apply must not queue a new mutation") end
        local result = api.import(bundle_str({ podkop = { content = PODKOP_CFG } }), nil, nil)
        assert.is_false(result.results.podkop.ok)
        assert.is_true(result.results.podkop.applied)
        assert.is_true(result.results.podkop.restart_required)
        assert.equal("inspect lock", result.results.podkop.details)
        assert.is_true(result.applied)
        assert.is_true(result.partial)
        assert.is_false(result.complete)
        assert.is_false(result.restarting)
    end)

    it("reports scheduling failure after state publication as an applied partial item", function()
        local api = begin_bundle({})
        require("podkop-tweaker.subsched").apply = function() return false, "launcher creation failed\nfull details" end
        local result = api.import(bundle_str({ subs = { data = { main = { false, { subscription_url = "https://sub/2" } },
            settings = { auto_update_interval = 4, auto_update_start = "01:30" } } } }), nil, nil)
        assert.is_false(result.results.subs.ok)
        assert.is_true(result.results.subs.applied)
        assert.is_true(result.results.subs.scheduling_required)
        assert.matches("Subscriptions saved, but scheduling failed", result.results.subs.error)
        assert.truthy(result.results.subs.details:find("full details", 1, true))
        assert.is_true(result.applied)
        assert.is_true(result.partial)
        assert.is_false(result.complete)
        assert.equal("https://sub/2", json.parse(H.vfs_read(SUBS)).main[2].subscription_url)
    end)

    it("preserves known applied outcomes through a finishing exception", function()
        local api = begin_bundle({})
        require("podkop-tweaker.subsched").apply = function() error("scheduler exception after write") end
        local result = api.import(bundle_str({ subs = { data = {} } }), nil, nil)
        assert.is_false(result.results.subs.ok)
        assert.is_true(result.results.subs.applied)
        assert.is_true(result.results.subs.unknown)
        assert.is_true(result.applied)
        assert.is_true(result.unknown)
        assert.is_true(result.partial)
        assert.truthy(result.results.subs.details:find("scheduler exception after write", 1, true))
        assert.is_table(json.parse(H.vfs_read(SUBS)))
    end)
end)

describe("bundle generic/state critical sections", function()
    for _, item in ipairs({
        { name = "fragment", path = "/etc/config/podkop-fragment", content = FRAG_CFG, lock = "/var/lock/podkop-fragment.lock" },
        { name = "tweaker", path = "/etc/config/podkop-tweaker", content = TWEAKER_CFG, lock = "/var/lock/podkop-tweaker-tweaker.lock" }
    }) do
        it("keeps " .. item.name .. " backup/publication under its resource lock", function()
            local api = begin_bundle({})
            H.vfs_write(item.path, item.content .. "# previous\n")
            local srv = require("podkop-tweaker.services")
            local write = srv.write_file_atomic
            srv.write_file_atomic = function(path, bytes, options)
                assert.is_true(H.state().dirs[item.lock])
                return write(path, bytes, options)
            end
            local result = api.import(bundle_str({ [item.name] = { content = item.content } }), nil, nil)
            assert.is_true(result.results[item.name].ok)
            assert.is_true(result.results[item.name].applied)
            assert.equal(item.content, H.vfs_read(item.path))
            assert.equal(item.content .. "# previous\n", H.vfs_read(item.path .. ".bundle-backup"))
            assert.falsy(H.state().dirs[item.lock])
        end)

        it("refuses a busy " .. item.name .. " lock without clearing another invocation", function()
            local api = begin_bundle({})
            H.vfs_write(item.path, item.content .. "# preserve\n")
            H.state().dirs[item.lock] = true
            local result = api.import(bundle_str({ [item.name] = { content = item.content } }), nil, nil)
            assert.is_false(result.results[item.name].ok)
            assert.falsy(result.applied)
            assert.equal(item.content .. "# preserve\n", H.vfs_read(item.path))
            assert.is_true(H.state().dirs[item.lock])
        end)

        it("preserves live/backup on " .. item.name .. " source close failure", function()
            local api = begin_bundle({ failures = { [item.path] = { close = true } } })
            H.vfs_write(item.path, item.content .. "# preserve\n")
            H.vfs_write(item.path .. ".bundle-backup", "usable previous backup")
            local result = api.import(bundle_str({ [item.name] = { content = item.content } }), nil, nil)
            assert.is_false(result.results[item.name].ok)
            assert.falsy(result.results[item.name].applied)
            assert.equal(item.content .. "# preserve\n", H.vfs_read(item.path))
            assert.equal("usable previous backup", H.vfs_read(item.path .. ".bundle-backup"))
        end)

        it("does not replace a usable " .. item.name .. " backup with an empty current source", function()
            local api = begin_bundle({})
            H.vfs_write(item.path, "")
            H.vfs_write(item.path .. ".bundle-backup", item.content .. "# known good\n")
            local result = api.import(bundle_str({ [item.name] = { content = item.content } }), nil, nil)
            assert.is_true(result.results[item.name].ok)
            assert.truthy(result.results[item.name].warning)
            assert.equal(item.content .. "# known good\n", H.vfs_read(item.path .. ".bundle-backup"))
        end)

        it("rejects a failed unique " .. item.name .. " stage without publishing its partial bytes", function()
            local api = begin_bundle({ failures = { [item.path .. ".tmp-write.*"] = { write = true, partial = 5 } } })
            H.vfs_write(item.path, item.content .. "# preserve\n")
            local result = api.import(bundle_str({ [item.name] = { content = item.content } }), nil, nil)
            assert.is_false(result.results[item.name].ok)
            assert.falsy(result.results[item.name].applied)
            assert.equal(item.content .. "# preserve\n", H.vfs_read(item.path))
        end)

        it("retains the existing " .. item.name .. " recovery copy if its backup stage cannot close", function()
            local api = begin_bundle({ failures = { [item.path .. ".bundle-backup.tmp-write.*"] = { close = true } } })
            H.vfs_write(item.path, item.content .. "# preserve\n")
            H.vfs_write(item.path .. ".bundle-backup", item.content .. "# older usable\n")
            local result = api.import(bundle_str({ [item.name] = { content = item.content } }), nil, nil)
            assert.is_false(result.results[item.name].ok)
            assert.falsy(result.results[item.name].applied)
            assert.equal(item.content .. "# preserve\n", H.vfs_read(item.path))
            assert.equal(item.content .. "# older usable\n", H.vfs_read(item.path .. ".bundle-backup"))
        end)
    end

    it("retains known disk application if lock release fails after the generic write", function()
        local lock = "/var/lock/podkop-tweaker-tweaker.lock"
        local api = begin_bundle({ failures = { [lock] = { rmdir = true } } })
        local result = api.import(bundle_str({ tweaker = { content = TWEAKER_CFG } }), nil, nil)
        assert.is_false(result.results.tweaker.ok)
        assert.is_true(result.results.tweaker.applied)
        assert.equal("string", type(result.results.tweaker.lock_error))
        assert.is_true(result.results.tweaker.unknown)
        assert.is_true(result.applied)
        assert.is_true(result.unknown)
        assert.is_true(result.partial)
        assert.equal(TWEAKER_CFG, H.vfs_read("/etc/config/podkop-tweaker"))
        assert.is_true(H.state().dirs[lock])
    end)

    it("does not overwrite an external Fragment source change observed after backup", function()
        local api = begin_bundle({})
        local path = "/etc/config/podkop-fragment"
        local original, external = FRAG_CFG .. "# original\n", FRAG_CFG .. "# external edit\n"
        H.vfs_write(path, original)
        local srv = require("podkop-tweaker.services")
        local write = srv.write_file_atomic
        srv.write_file_atomic = function(target, bytes, options)
            local ok, err = write(target, bytes, options)
            if target == path .. ".bundle-backup" and ok then H.vfs_write(path, external) end
            return ok, err
        end
        local result = api.import(bundle_str({ fragment = { content = FRAG_CFG } }), nil, nil)
        assert.is_false(result.results.fragment.ok)
        assert.matches("changed during import", result.results.fragment.error)
        assert.falsy(result.results.fragment.applied)
        assert.is_true(result.results.fragment.backup_created)
        assert.equal(external, H.vfs_read(path))
        assert.equal(original, H.vfs_read(path .. ".bundle-backup"))
    end)

    for _, case in ipairs({
        { label = "invalid JSON", content = "{broken" },
        { label = "empty file", content = "" },
        { label = "read failure", content = '{"version":1}', failure = { read = true } },
        { label = "close failure", content = '{"version":1}', failure = { close = true } }
    }) do
        it("stops dependent subscription import on current " .. case.label, function()
            local api = begin_bundle({ failures = case.failure and { [SUBS] = case.failure } or {} })
            H.vfs_write(SUBS, case.content)
            H.vfs_write(SUBS .. ".bundle-backup", "keep backup")
            require("podkop-tweaker.subsched").apply = function() error("unreadable state must not change scheduling") end
            local result = api.import(bundle_str({ subs = { data = {} } }), nil, nil)
            assert.is_false(result.results.subs.ok)
            assert.matches("Cannot read current subscriptions", result.results.subs.error)
            assert.falsy(result.applied)
            assert.equal(case.content, H.vfs_read(SUBS))
            assert.equal("keep backup", H.vfs_read(SUBS .. ".bundle-backup"))
        end)
    end

    it("keeps state write and scheduler setup under the short subscriptions lock", function()
        local api = begin_bundle({})
        local srv, sched = require("podkop-tweaker.services"), require("podkop-tweaker.subsched")
        local write, apply = srv.write_file_atomic, sched.apply
        local lock = "/var/lock/podkop-tweaker-subscriptions.lock"
        srv.write_file_atomic = function(path, bytes, options)
            assert.is_true(H.state().dirs[lock])
            return write(path, bytes, options)
        end
        sched.apply = function(...)
            assert.is_true(H.state().dirs[lock])
            return apply(...)
        end
        local result = api.import(bundle_str({ subs = { data = { version = 7, future = "keep",
            metadata = { future = true }, settings = { future_option = "keep" },
            main = { false, { subscription_url = "https://sub/2", future_slot = "keep" }, false } } } }), nil, nil)
        assert.is_true(result.results.subs.ok)
        local state = require("pt-subs-lib").read_subs(SUBS)
        assert.equal(7, state.version)
        assert.equal("keep", state.future)
        assert.is_true(state.metadata.future)
        assert.equal("keep", state.settings.future_option)
        assert.equal("keep", state.main[2].future_slot)
        assert.is_false(state.main[1])
        assert.is_false(state.main[3])
        assert.falsy(H.state().dirs[lock])
    end)

    it("propagates final subscription state-write failure without reporting an applied item", function()
        local api = begin_bundle({ failures = { [SUBS .. ".tmp.*"] = { close = true } } })
        H.vfs_write(SUBS, '{"version":1,"future":"keep"}')
        local result = api.import(bundle_str({ subs = { data = {} } }), nil, nil)
        assert.is_false(result.results.subs.ok)
        assert.falsy(result.results.subs.applied)
        assert.matches("Cannot write subscriptions file", result.results.subs.error)
        assert.equal('{"version":1,"future":"keep"}', H.vfs_read(SUBS))
    end)

    it("imports a normal empty first-run subscription state successfully", function()
        local api = begin_bundle({})
        local result = api.import(bundle_str({ subs = { data = {} } }), nil, nil)
        assert.is_true(result.success)
        assert.is_true(result.complete)
        assert.is_true(result.results.subs.applied)
        assert.equal(1, json.parse(H.vfs_read(SUBS)).version)
    end)
end)

describe("bundle uncertainty and primary failure preservation", function()
    for _, case in ipairs({
        { name = "unpublished uncertain failure", written = false, unknown = true },
        { name = "published uncertain failure", written = false, published = true, unknown = true },
        { name = "uncertain success without publication proof", written = true, unknown = true },
        { name = "success without publication metadata", written = true }
    }) do
        it("keeps the write_subs four-result contract for " .. case.name, function()
            local api = begin_bundle({})
            local subs, sched = require("pt-subs-lib"), require("podkop-tweaker.subsched")
            local write, writes, schedules = subs.write_subs, 0, 0
            local original = '{"version":1,"future":"original"}'
            local details = "state write diagnostic\n" .. string.rep("full state detail\n", 800) .. "last state detail"
            H.vfs_write(SUBS, original)
            subs.write_subs = function(data, path)
                writes = writes + 1
                local applied
                if case.published then
                    local ok, err, actual = write(data, path)
                    assert.is_true(ok, err)
                    applied = actual
                end
                return case.written, case.unknown and details or nil, applied, case.unknown
            end
            sched.apply = function() schedules = schedules + 1; return true end
            local result = api.import(bundle_str({ subs = { data = { future = "imported" } } }), nil, nil)
            local item = result.results.subs
            assert.is_false(item.ok)
            assert.is_true(item.unknown)
            assert.is_true(result.unknown)
            assert.is_false(result.complete)
            assert.equal(1, writes, "an uncertain write must not be replayed")
            assert.equal(0, schedules, "uncertain state must not trigger dependent scheduling")
            if case.published then
                assert.is_true(item.applied)
                assert.is_true(item.state_saved)
                assert.is_true(result.applied)
                assert.equal("imported", json.parse(H.vfs_read(SUBS)).future)
            else
                assert.falsy(item.applied, "release uncertainty is not publication evidence")
                assert.is_false(result.applied)
                assert.equal(original, H.vfs_read(SUBS))
            end
            if case.unknown then assert.equal(details, item.details) end
        end)
    end

    it("retains a primary state-read failure if the enclosing item lock also fails release", function()
        local lock = "/var/lock/podkop-tweaker-subscriptions.lock"
        local api = begin_bundle({ failures = { [lock] = { rmdir = true } } })
        local original = '{"version":1,"future":"original"}'
        local details = "current state read failure\n" .. string.rep("read diagnostic\n", 800) .. "last read detail"
        H.vfs_write(SUBS, original)
        H.vfs_write(SUBS .. ".bundle-backup", "previous recovery copy")
        require("pt-subs-lib").read_subs = function() return nil, details end
        local result = api.import(bundle_str({ subs = { data = {} } }), nil, nil)
        local item = result.results.subs
        assert.is_false(item.ok)
        assert.falsy(item.applied)
        assert.is_false(result.applied)
        assert.is_true(item.unknown)
        assert.is_true(result.unknown)
        assert.equal(item.lock_error, item.error)
        assert.equal("Cannot read current subscriptions: " .. details, item.primary_error)
        assert.equal(details, item.primary_details)
        assert.truthy(item.details:find(details, 1, true))
        assert.truthy(item.details:find(item.lock_error, 1, true))
        assert.equal(original, H.vfs_read(SUBS))
        assert.equal("previous recovery copy", H.vfs_read(SUBS .. ".bundle-backup"))
    end)

    for _, case in ipairs({
        { name = "legacy partial/uncertain failure", ok = false, third = true },
        { name = "explicit unknown failure", ok = false, unknown = true },
        { name = "explicit unknown success", ok = true, unknown = true }
    }) do
        it("propagates scheduler " .. case.name .. " after factual state publication", function()
            local api = begin_bundle({})
            local details = "scheduler output\n" .. string.rep("scheduler diagnostic\n", 800) .. "last scheduler detail"
            require("podkop-tweaker.subsched").apply = function() return case.ok, details, case.third, case.unknown end
            local result = api.import(bundle_str({ subs = { data = { future = "imported" } } }), nil, nil)
            local item = result.results.subs
            assert.is_false(item.ok)
            assert.is_true(item.applied)
            assert.is_true(item.unknown)
            assert.is_true(item.scheduling_required)
            assert.equal(details, item.details)
            assert.is_true(result.applied)
            assert.is_true(result.unknown)
            assert.is_false(result.complete)
            assert.equal("imported", json.parse(H.vfs_read(SUBS)).future)
        end)
    end

    it("does not infer service publication from a success flag without applied evidence", function()
        local api = begin_bundle({})
        local srv = require("podkop-tweaker.services")
        srv.apply_service = function() return { success = true, warning = "retain this metadata" } end
        local result = api.import(bundle_str({ podkop = { content = PODKOP_CFG } }), nil, nil)
        assert.is_false(result.results.podkop.ok)
        assert.falsy(result.results.podkop.applied)
        assert.equal("retain this metadata", result.results.podkop.warning)
        assert.is_false(result.applied)
        assert.is_true(result.unknown)
        assert.is_false(result.complete)
        assert.equal(0, restart_count("podkop"))
    end)

    it("keeps shared service primary metadata and uncertainty without another restart", function()
        local api = begin_bundle({})
        local srv = require("podkop-tweaker.services")
        local details = "primary full output\n" .. string.rep("service detail\n", 800) .. "last service detail"
        srv.apply_service = function()
            return { success = false, applied = true, unknown = true, error = "service lock release failed",
                lock_error = "service lock release failed", primary_error = "primary service failure", primary_details = details,
                details = "primary service failure\n" .. details .. "\nservice lock release failed", warning = "backup retained" }
        end
        local result = api.import(bundle_str({ podkop = { content = PODKOP_CFG } }), nil, nil)
        local item = result.results.podkop
        assert.is_false(item.ok)
        assert.is_true(item.applied)
        assert.is_true(item.unknown)
        assert.equal("service lock release failed", item.error)
        assert.equal(item.error, item.lock_error)
        assert.equal("primary service failure", item.primary_error)
        assert.equal(details, item.primary_details)
        assert.truthy(item.details:find(details, 1, true))
        assert.equal("backup retained", item.warning)
        assert.is_true(result.unknown)
        assert.is_true(result.applied)
        assert.is_false(result.complete)
        assert.equal(0, restart_count("podkop"))
    end)

    it("does not turn failed service validation plus release uncertainty into an applied config", function()
        local lock = "/var/lock/podkop-tweaker-podkop.lock"
        local api = begin_bundle({ failures = { [lock] = { rmdir = true } } })
        local result = api.import(bundle_str({ podkop = { content = "invalid uci garbage" } }), nil, nil)
        local item = result.results.podkop
        assert.is_false(item.ok)
        assert.falsy(item.applied)
        assert.is_false(result.applied)
        assert.is_true(item.unknown)
        assert.is_true(result.unknown)
        assert.equal(item.lock_error, item.error)
        assert.truthy(item.details:find("Invalid UCI format", 1, true))
        assert.equal(PODKOP_CFG, H.vfs_read("/etc/config/podkop"))
        assert.equal(0, restart_count("podkop"))
    end)

    for _, accepted in ipairs({ false, true }) do
        it("retains " .. (accepted and "accepted" or "failed") .. " restart evidence and full errors when finishing release fails", function()
            local lock = "/var/lock/podkop-tweaker-podkop.lock"
            local details = "native restart output\n" .. string.rep("restart diagnostic\n", 800) .. "last restart detail"
            local api = begin_bundle({
                sys = {
                    { match = "pidof ", out = "321\nPT_EXIT:0\n" },
                    { match = "/etc/init.d/podkop restart", out = function()
                        -- Fail only the finishing release, after the write
                        -- phase already released the resource cleanly.
                        H.state().failures[lock] = { rmdir = true }
                        return accepted and "\nPT_EXIT:0\n" or details .. "\nPT_EXIT:9\n"
                    end }
                }
            })
            H.vfs_write("/proc/321/stat", "321 (sing-box) S" .. string.rep(" 0", 18) .. " 9876\n")
            local result = api.import(bundle_str({ podkop = { content = PODKOP_CFG } }), nil, nil)
            local item = result.results.podkop
            local releases = 0
            for _, event in ipairs(H.state().io_log) do
                if event.operation == "rmdir" and event.path == lock then releases = releases + 1 end
            end
            assert.equal(2, releases)
            assert.equal(1, restart_count("podkop"))
            assert.is_false(item.ok)
            assert.is_true(item.applied)
            assert.is_true(item.unknown)
            assert.is_true(item.restart.unknown)
            assert.equal("string", type(item.restart.lock_error))
            assert.equal(item.restart.lock_error, item.lock_error)
            assert.equal(accepted, item.restarting)
            assert.equal(accepted, result.restarting)
            assert.is_true(item.previous_running)
            assert.is_true(item.previous_identity_known)
            assert.equal("321:9876", item.previous_instance)
            assert.equal("321:9876", item.restart.previous_instance)
            assert.equal("321:9876", result.previous_instance)
            assert.is_true(result.verification_required)
            assert.is_true(result.applied)
            assert.is_true(result.unknown)
            assert.is_false(result.complete)
            if accepted then
                assert.falsy(item.restart_required, "an acknowledged restart is not an automatic re-apply instruction")
            else
                assert.is_true(item.restart_required)
                assert.equal("Service restart command failed", item.restart.primary_error)
                assert.equal(details, item.restart.primary_details)
                assert.equal(details, item.primary_details)
                assert.truthy(item.details:find(details, 1, true))
                assert.truthy(item.details:find(item.lock_error, 1, true))
            end
        end)
    end

    it("lifts nested restart uncertainty without losing extra restart metadata", function()
        local api = begin_bundle({})
        require("podkop-tweaker.services").restart_service = function()
            return { success = true, restarting = true, unknown = true, verification_required = true,
                previous_running = false, previous_identity_known = true, diagnostic = { source = "unverified native result" } }
        end
        local result = api.import(bundle_str({ podkop = { content = PODKOP_CFG } }), nil, nil)
        local item = result.results.podkop
        assert.is_false(item.ok)
        assert.is_true(item.unknown)
        assert.is_true(result.unknown)
        assert.is_false(result.complete)
        assert.is_false(item.previous_running)
        assert.is_true(item.previous_identity_known)
        assert.same({ source = "unverified native result" }, item.restart.diagnostic)
    end)

    it("keeps the top mutation gate uncertain alongside an independently successful item", function()
        local api = begin_bundle({})
        require("pt-subs-lib").write_subs = function() return false, "unverified state write", nil, true end
        local result = api.import(bundle_str({ fragment = { content = FRAG_CFG }, subs = { data = {} } }), nil, nil)
        assert.is_true(result.results.fragment.ok)
        assert.is_true(result.results.fragment.applied)
        assert.falsy(result.results.subs.applied)
        assert.is_true(result.results.subs.unknown)
        assert.is_true(result.success)
        assert.is_true(result.applied)
        assert.is_true(result.partial)
        assert.is_true(result.unknown)
        assert.is_false(result.complete)
    end)

    it("reports a read-only Argon export lock uncertainty without creating an attachment", function()
        local run = begin_export("podkop,argon")
        require("podkop-tweaker.argon").read_settings = function() return nil, "read lock release failed", true end
        local result = export_failure(run, 500, "argon")
        assert.is_true(result.errors.argon.unknown)
        assert.is_true(result.unknown)
    end)
end)
