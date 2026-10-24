-- Typed typography reads, owned CSS publication/removal and partial API outcomes.
-- Native UCI/RPC remains a controlled fixture, not router integration evidence.

package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path

local H = require("pt_harness")

local CSS = "/www/luci-static/argon/css/cascade.css"
local CONFIG = "/etc/config/argon"
local LOCK = "/var/lock/podkop-tweaker-argon-css.lock"
local MARKER_S = "/* === Podkop Tweaker Typography === */"
local MARKER_E = "/* === End Podkop Tweaker Typography === */"

local function fixture_uci()
    local lines = {}
    local function quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
    for _, section in ipairs(H.state().uci.argon or {}) do
        lines[#lines + 1] = "config " .. quote(section[".type"]) .. " " .. quote(section[".name"]) .. "\n"
        local keys = {}
        for key in pairs(section) do if key:sub(1, 1) ~= "." then keys[#keys + 1] = key end end
        table.sort(keys)
        for _, key in ipairs(keys) do
            local value = section[key]
            if type(value) == "table" then
                for _, item in ipairs(value) do lines[#lines + 1] = " list " .. quote(key) .. " " .. quote(item) .. "\n" end
            else lines[#lines + 1] = " option " .. quote(key) .. " " .. quote(value) .. "\n" end
        end
    end
    return table.concat(lines)
end

local function begin_argon(opts)
    opts = opts or {}
    opts.strict = true
    H.begin(opts)
    local LIB = require("podkop-tweaker.lib")
    LIB.ARGON_CASCADE_CSS = CSS
    local uci = require("luci.model.uci").cursor()
    uci:set("podkop-tweaker", "settings", "settings")
    uci:set("podkop-tweaker", "settings", "show_argon_tab", "1")
    H.state().uci.argon = H.state().uci.argon or { H.sec("global", "global", { mode = "normal" }) }
    H.vfs_write(CONFIG, fixture_uci())
    -- Native LuCI get_all is a package read (false,error on RPC/parser failure),
    -- not eight independent get() calls. Older harness versions lack this fake.
    if type(uci.get_all) ~= "function" then
        function uci:get_all(config, name)
            local sections = H.state().uci[config]
            if not sections then return false, "Entry not found" end
            local result = {}
            for _, section in ipairs(sections) do
                if name == section[".name"] then return section end
                result[section[".name"]] = section
            end
            if name then return false, "Entry not found" end
            return result
        end
    end
    local commit = uci.commit
    function uci:commit(config)
        local ok, err = commit(self, config)
        if ok and config == "argon" then H.vfs_write(CONFIG, fixture_uci()) end
        return ok, err
    end
end

local function enable_tab()
    local uci = require("luci.model.uci").cursor()
    uci:set("podkop-tweaker", "settings", "show_argon_tab", "1")
end

local function saved_uci()
    local uci = require("luci.model.uci").cursor()
    local out = {}
    for _, f in ipairs({ "font_size", "font_family", "font_family_custom", "font_weight",
        "line_height", "letter_spacing", "menu_font_size", "menu_padding" }) do
        out[f] = uci:get("argon", "typography", f)
    end
    return out
end

local function no_live_write()
    for _, entry in ipairs(H.state().io_log) do
        if entry.operation == "open" and entry.path == CSS then
            assert.equal("r", entry.mode:sub(1, 1), "the live stylesheet must never be opened for writing")
        end
    end
end

local function css_stages()
    return H.stage_paths(CSS .. ".pt-typography.*")
end

local function no_css_stages()
    for _, path in ipairs(css_stages()) do assert.is_false(H.vfs_exists(path), path) end
    no_live_write()
end

after_each(function()
    H.finish()
end)

describe("api_argon.typography", function()
    it("returns settings with defaults, stale flag and sorted families", function()
        begin_argon({
            uci = {
                argon = { H.sec("typography", "typography", {
                    font_size = "16",
                    font_weight = "550"
                }) }
            }
        })
        H.vfs_write(CSS, "x " .. MARKER_S .. " b " .. MARKER_E .. " y")
        local ARG = H.reload("podkop-tweaker.api_argon")
        local resp = ARG.typography()
        assert.falsy(resp.error)
        assert.same({
            font_size = "16",
            font_family = "Google Sans",
            font_family_custom = "",
            font_weight = "550",
            line_height = "",
            letter_spacing = "",
            menu_font_size = "",
            menu_padding = ""
        }, resp.settings)
        assert.is_false(resp.stale)
        assert.equal("uci", resp.settings_source)
        assert.is_false(resp.config_missing)
        assert.same({ "Arial", "Google Sans", "Tahoma", "Verdana", "monospace", "system-ui" },
            resp.font_families)
    end)

    it("reports a missing CSS read as an error, and a readable unmarked file as stale", function()
        begin_argon({})
        local ARG = H.reload("podkop-tweaker.api_argon")
        local missing = ARG.typography()
        assert.truthy(missing.error)
        assert.is_nil(missing.stale)
        assert.is_nil(missing.settings)
        H.vfs_write(CSS, "plain css without markers\n")
        assert.is_true(ARG.typography().stale)
    end)

    it("permits explicit first-run defaults only for a missing configuration", function()
        begin_argon({})
        os.remove(CONFIG)
        H.state().uci.argon = nil
        H.vfs_write(CSS, ".theme{}\n")
        local resp = H.reload("podkop-tweaker.api_argon").typography()
        assert.falsy(resp.error)
        assert.equal("defaults", resp.settings_source)
        assert.is_true(resp.config_missing)
        assert.equal("Google Sans", resp.settings.font_family)
        assert.equal("400", resp.settings.font_weight)
        assert.equal("", resp.settings.font_size)
        assert.is_false(H.vfs_exists(CONFIG))
        assert.same({}, H.commits())
    end)

    for _, operation in ipairs({ "open", "read", "close" }) do
        local fail = operation
        for _, path in ipairs({ CONFIG, CSS }) do
            local source = path
            it("returns no defaults or CSS-active flag after " .. source .. " " .. fail .. " failure", function()
                begin_argon({ failures = { [source] = { [fail] = true } } })
                H.vfs_write(CSS, MARKER_S .. "existing" .. MARKER_E)
                local resp = H.reload("podkop-tweaker.api_argon").typography()
                assert.truthy(resp.error)
                assert.is_nil(resp.settings)
                assert.is_nil(resp.stale)
                assert.same({}, H.commits())
                assert.equal(MARKER_S .. "existing" .. MARKER_E, H.vfs_read(CSS))
                no_live_write()
            end)
        end
    end

    for _, raw in ipairs({ "", " \r\n\t", string.rep("x", 1048577) }) do
        local content = raw
        it("rejects an empty, whitespace or oversized existing UCI file", function()
            begin_argon({})
            H.vfs_write(CONFIG, content)
            H.vfs_write(CSS, ".theme{}\n")
            local resp = H.reload("podkop-tweaker.api_argon").typography()
            assert.truthy(resp.error)
            assert.is_nil(resp.settings)
            assert.same({}, H.commits())
        end)
    end

    it("distinguishes a native UCI parser/RPC error from an absent typography section", function()
        begin_argon({})
        H.vfs_write(CSS, ".theme{}\n")
        local uci = require("luci.model.uci").cursor()
        uci.get_all = function() return false, "UCI parser or RPC failed" end
        local resp = H.reload("podkop-tweaker.api_argon").typography()
        assert.equal("UCI parser or RPC failed", resp.error)
        assert.is_nil(resp.settings)
        assert.is_nil(resp.stale)
        assert.same({}, H.commits())
    end)

    for _, malformed in ipairs({ { error = "UCI unavailable" }, { typography = false },
        { typography = { [".name"] = "another", [".type"] = "typography" } } }) do
        local value = malformed
        it("rejects an error-shaped or malformed package response", function()
            begin_argon({})
            H.vfs_write(CSS, ".theme{}\n")
            require("luci.model.uci").cursor().get_all = function() return value end
            local resp = H.reload("podkop-tweaker.api_argon").typography()
            assert.truthy(resp.error)
            assert.is_nil(resp.settings)
            assert.is_nil(resp.stale)
            assert.same({}, H.commits())
        end)
    end

    for _, field in ipairs({
        { "font_size", "99" }, { "font_weight", "heavy" }, { "line_height", false },
        { "letter_spacing", { "0.2" } }, { "font_family", {} },
        { "font_family_custom", "Family; background:url(x)" }
    }) do
        local invalid = field
        it("does not normalize invalid persisted " .. invalid[1] .. " into defaults", function()
            begin_argon({ uci = { argon = { H.sec("typography", "typography", { [invalid[1]] = invalid[2] }) } } })
            H.vfs_write(CSS, ".theme{}\n")
            local resp = H.reload("podkop-tweaker.api_argon").typography()
            assert.equal("Invalid Argon typography setting: " .. invalid[1], resp.error)
            assert.is_nil(resp.settings)
            assert.same({}, H.commits())
        end)
    end

    it("rejects a conflicting section type without overwriting it", function()
        begin_argon({ uci = { argon = { H.sec("typography", "unknown_plugin", { future = "keep" }) } } })
        H.vfs_write(CSS, ".theme{}\n")
        local ARG = H.reload("podkop-tweaker.api_argon")
        assert.equal("Invalid Argon typography section", ARG.typography().error)
        assert.is_false(ARG.typography_reset().success)
        assert.equal("unknown_plugin", require("luci.model.uci").cursor():get("argon", "typography"))
        assert.same({}, H.commits())
    end)

    it("disabled tab -> exact error for every endpoint", function()
        begin_argon({})
        local uci = require("luci.model.uci").cursor()
        uci:set("podkop-tweaker", "settings", "show_argon_tab", "0")
        local ARG = H.reload("podkop-tweaker.api_argon")
        local disabled = { error = "Argon tab is disabled" }
        assert.same(disabled, ARG.typography())
        assert.same(disabled, ARG.typography_save({}))
        assert.same(disabled, ARG.typography_reset())
        assert.same(disabled, ARG.reinject())
    end)
end)

describe("api_argon.typography_save", function()
    it("valid payload: stores values, regenerates block in place, keeps tail", function()
        begin_argon({})
        H.vfs_write(CSS, "body{color:red}\n" .. MARKER_S .. "\nfont-size: 99px;\n" ..
            MARKER_E .. "\n.footer{}\n")
        local ARG = H.reload("podkop-tweaker.api_argon")
        local resp = ARG.typography_save({
            font_size = "16",
            font_family = "custom",
            font_family_custom = 'My<Font>"X";url(p)',
            font_weight = "550",
            line_height = "1.4",
            letter_spacing = "-0.5",
            menu_font_size = "1.1",
            menu_padding = "12"
        })
        assert.is_true(resp.success)
        assert.is_false(resp.stale)
        assert.same({ "argon" }, H.commits())
        local u = saved_uci()
        assert.equal("16", u.font_size)
        assert.equal("custom", u.font_family)
        assert.equal("MyFontXurlp", u.font_family_custom)
        assert.equal("550", u.font_weight)
        assert.equal("1.4", u.line_height)
        assert.equal("-0.5", u.letter_spacing)
        assert.equal("1.1", u.menu_font_size)
        assert.equal("12", u.menu_padding)
        local css = H.vfs_read(CSS)
        assert.truthy(css:find("font%-size: 16px;"))
        assert.falsy(css:find("99px"))
        assert.truthy(css:find("footer", 1, true))
        assert.truthy(css:find(MARKER_S, 1, true))
    end)

    it("no markers yet -> block appended", function()
        begin_argon({})
        H.vfs_write(CSS, ".base{}\n")
        local ARG = H.reload("podkop-tweaker.api_argon")
        local resp = ARG.typography_save({ font_size = "14" })
        assert.is_true(resp.success)
        local css = H.vfs_read(CSS)
        assert.truthy(css:find("^%.base%{%}"))
        assert.truthy(css:find("font%-size: 14px;"))
    end)

    it("range clamps reject out-of-bounds and garbage", function()
        begin_argon({})
        local ARG = H.reload("podkop-tweaker.api_argon")
        ARG.typography_save({
            font_size = "21",
            font_weight = "abc",
            line_height = "2.5",
            letter_spacing = "-1",
            menu_font_size = "0.5",
            menu_padding = "4"
        })
        local u = saved_uci()
        assert.equal("", u.font_size)
        assert.equal("400", u.font_weight)
        assert.equal("", u.line_height)
        assert.equal("", u.letter_spacing)
        assert.equal("", u.menu_font_size)
        assert.equal("", u.menu_padding)
    end)

    it("range boundaries are accepted", function()
        begin_argon({})
        local ARG = H.reload("podkop-tweaker.api_argon")
        ARG.typography_save({
            font_size = "13",
            font_weight = "700",
            line_height = "2.0",
            letter_spacing = "2.0",
            menu_font_size = "1.2",
            menu_padding = "20"
        })
        local u = saved_uci()
        assert.equal("13", u.font_size)
        assert.equal("700", u.font_weight)
        assert.equal("2.0", u.line_height)
        assert.equal("2.0", u.letter_spacing)
        assert.equal("1.2", u.menu_font_size)
        assert.equal("20", u.menu_padding)
    end)

    it("unknown family name is stored verbatim (dropdown contract)", function()
        begin_argon({})
        local ARG = H.reload("podkop-tweaker.api_argon")
        ARG.typography_save({ font_family = "Ninja" })
        assert.equal("Ninja", saved_uci().font_family)
    end)

    it("rejects untyped form values without a write or an exception", function()
        begin_argon({})
        H.vfs_write(CSS, ".theme{}\n")
        local ARG = H.reload("podkop-tweaker.api_argon")
        for _, input in ipairs({ "bad", false, { font_family_custom = {} }, { font_size = true }, { font_weight = 500 } }) do
            local resp = ARG.typography_save(input)
            assert.is_false(resp.success)
            assert.truthy(resp.error)
        end
        assert.same({}, H.commits())
        assert.equal(".theme{}\n", H.vfs_read(CSS))
    end)

    it("empty payload falls back to defaults", function()
        begin_argon({})
        H.vfs_write(CSS, ".base{}\n")
        local ARG = H.reload("podkop-tweaker.api_argon")
        local resp = ARG.typography_save({})
        assert.is_true(resp.success)
        local u = saved_uci()
        assert.equal("", u.font_size)
        assert.equal("Google Sans", u.font_family)
        assert.equal("", u.font_family_custom)
        assert.equal("400", u.font_weight)
        assert.equal("typography", require("luci.model.uci").cursor():get("argon", "typography"))
    end)

    it("missing CSS after UCI save is a partial failure, with unknown CSS status", function()
        begin_argon({})
        local ARG = H.reload("podkop-tweaker.api_argon")
        local resp = ARG.typography_save({ font_size = "15" })
        assert.is_false(resp.success)
        assert.truthy(resp.error)
        assert.is_true(resp.partial)
        assert.is_true(resp.uci_saved)
        assert.is_false(resp.css_applied)
        assert.is_nil(resp.stale)
        assert.truthy(resp.stale_error)
        assert.equal("15", saved_uci().font_size)
    end)
end)

describe("api_argon.typography_reset", function()
    it("writes defaults, removes css block, reports stale", function()
        begin_argon({
            uci = { argon = { H.sec("typography", "typography", { font_size = "18" }) } }
        })
        H.vfs_write(CSS, "pre\n" .. MARKER_S .. "old" .. MARKER_E .. "\ntail\n")
        local ARG = H.reload("podkop-tweaker.api_argon")
        local resp = ARG.typography_reset()
        assert.is_true(resp.success)
        assert.is_true(resp.stale)
        local u = saved_uci()
        assert.equal("", u.font_size)
        assert.equal("Google Sans", u.font_family)
        assert.equal("400", u.font_weight)
        local css = H.vfs_read(CSS)
        assert.falsy(css:find("old", 1, true))
        assert.falsy(css:find(MARKER_S, 1, true))
        assert.equal("pre\n\ntail\n", css)
        assert.is_true(resp.uci_saved)
        assert.is_true(resp.css_applied)
        no_css_stages()
    end)

    it("missing CSS is an explicit partial reset failure", function()
        begin_argon({})
        local ARG = H.reload("podkop-tweaker.api_argon")
        local resp = ARG.typography_reset()
        assert.is_false(resp.success)
        assert.truthy(resp.error)
        assert.is_true(resp.partial)
        assert.is_true(resp.uci_saved)
        assert.is_false(resp.css_applied)
        assert.is_nil(resp.stale)
        assert.truthy(resp.stale_error)
        assert.is_false(H.vfs_exists(CSS))
    end)

    it("preserves every prefix and suffix byte, even adjacent rules and CRLF whitespace", function()
        begin_argon({})
        local prefix, suffix = "\r\n.theme{}\r\n\r\n", ".adjacent{}\r\n\r\n.footer{}\t "
        H.vfs_write(CSS, prefix .. MARKER_S .. "\r\nowned{}\r\n" .. MARKER_E .. suffix)
        local AR = require("podkop-tweaker.argon")
        assert.is_true(AR.remove_css())
        assert.equal(prefix .. suffix, H.vfs_read(CSS))
        assert.same({}, H.commits())
        no_css_stages()
    end)

    it("is idempotent on a readable stylesheet with no owned markers", function()
        begin_argon({})
        local original = ".theme{}\r\n\r\n.footer{}\t "
        H.vfs_write(CSS, original)
        local ARG = H.reload("podkop-tweaker.api_argon")
        for _ = 1, 2 do
            local resp = ARG.typography_reset()
            assert.is_true(resp.success)
            assert.is_true(resp.stale)
            assert.is_true(resp.uci_saved)
            assert.is_true(resp.css_applied)
            assert.equal(original, H.vfs_read(CSS))
        end
        assert.same({}, css_stages())
        no_live_write()
    end)

    it("bounds stylesheet reads and makes an oversized stale check explicitly unknown", function()
        begin_argon({})
        local original = string.rep("x", 4194305)
        H.vfs_write(CSS, original)
        local AR = require("podkop-tweaker.argon")
        local stale, stale_err = AR.check_stale()
        assert.is_nil(stale)
        assert.truthy(stale_err)
        local ok, err = AR.remove_css()
        assert.is_false(ok)
        assert.truthy(err)
        assert.equal(original, H.vfs_read(CSS))
        assert.same({}, css_stages())
        no_live_write()
    end)

    for _, empty in ipairs({ "", " \r\n\t" }) do
        local original = empty
        it("refuses an empty theme stylesheet instead of publishing a managed-only replacement", function()
            begin_argon({})
            H.vfs_write(CSS, original)
            local ARG = H.reload("podkop-tweaker.api_argon")
            local AR = require("podkop-tweaker.argon")
            local read = ARG.typography()
            assert.equal("Argon stylesheet is empty", read.error)
            assert.is_nil(read.settings)
            assert.is_nil(read.stale)
            local stale, stale_err = AR.check_stale()
            assert.is_nil(stale)
            assert.equal("Argon stylesheet is empty", stale_err)
            local injected, inject_err = AR.inject_css(require("podkop-tweaker.lib").generate_argon_css({}))
            assert.is_false(injected)
            assert.equal("Argon stylesheet is empty", inject_err)
            for _, action in ipairs({ "typography_save", "typography_reset", "reinject" }) do
                local response = ARG[action]({ font_size = "19" })
                assert.is_false(response.success)
                assert.equal("Argon stylesheet is empty", response.error)
                assert.is_false(response.css_applied)
                assert.is_nil(response.stale)
                if action ~= "reinject" then
                    assert.is_true(response.uci_saved)
                    assert.is_true(response.partial)
                end
                assert.equal(original, H.vfs_read(CSS))
            end
            assert.same({}, css_stages())
            no_live_write()
        end)
    end

    for _, malformed in ipairs({ MARKER_S .. "unterminated", "orphan" .. MARKER_E,
        MARKER_E .. MARKER_S, MARKER_S .. MARKER_S .. MARKER_E,
        MARKER_S .. MARKER_E .. MARKER_E, MARKER_S .. MARKER_E .. MARKER_S .. MARKER_E }) do
        local original = ".theme{}\n" .. malformed .. "\n.footer{}"
        it("rejects incomplete, reversed or duplicate markers without publication", function()
            begin_argon({})
            H.vfs_write(CSS, original)
            local ARG = H.reload("podkop-tweaker.api_argon")
            local read = ARG.typography()
            assert.truthy(read.error)
            assert.is_nil(read.stale)
            local resp = ARG.typography_reset()
            assert.is_false(resp.success)
            assert.is_true(resp.partial)
            assert.is_true(resp.uci_saved)
            assert.is_false(resp.css_applied)
            assert.truthy(resp.error)
            assert.equal(original, H.vfs_read(CSS))
            assert.same({}, css_stages())
            no_live_write()
        end)
    end
end)

describe("api_argon.reinject", function()
    it("regenerates block from current uci", function()
        begin_argon({
            uci = { argon = { H.sec("typography", "typography", { font_size = "19" }) } }
        })
        H.vfs_write(CSS, ".theme{}\n")
        local ARG = H.reload("podkop-tweaker.api_argon")
        local resp = ARG.reinject()
        assert.is_true(resp.success)
        assert.is_false(resp.stale)
        assert.truthy(H.vfs_read(CSS):find("19px"))
    end)

    it("failure without css file", function()
        begin_argon({})
        local ARG = H.reload("podkop-tweaker.api_argon")
        local resp = ARG.reinject()
        assert.is_false(resp.success)
        assert.truthy(resp.error)
        assert.is_nil(resp.stale)
        assert.is_false(resp.uci_saved)
        assert.is_false(resp.css_applied)
        assert.is_nil(resp.partial)
    end)

    it("enable_tab helper flips flag back on", function()
        begin_argon({})
        H.vfs_write(CSS, ".theme{}\n")
        local ARG = H.reload("podkop-tweaker.api_argon")
        local uci = require("luci.model.uci").cursor()
        uci:set("podkop-tweaker", "settings", "show_argon_tab", "0")
        assert.same({ error = "Argon tab is disabled" }, ARG.reinject())
        enable_tab()
        local resp = ARG.reinject()
        assert.falsy(resp.error)
    end)

    it("does not inject defaults after a failed current UCI read", function()
        begin_argon({ uci = { argon = { H.sec("typography", "typography", { font_size = "19" }) } } })
        H.vfs_write(CSS, ".existing{}\n")
        require("luci.model.uci").cursor().get_all = function() return nil, "UCI unavailable" end
        local resp = H.reload("podkop-tweaker.api_argon").reinject()
        assert.is_false(resp.success)
        assert.equal("UCI unavailable", resp.error)
        assert.is_false(resp.uci_saved)
        assert.is_false(resp.css_applied)
        assert.equal(".existing{}\n", H.vfs_read(CSS))
        assert.same({}, H.commits())
        assert.same({}, css_stages())
    end)
end)

describe("api_argon theme wrappers", function()
    it("normalizes only true and the form flag 1 into a forced check, including with the tab hidden", function()
        begin_argon({})
        require("luci.model.uci").cursor():set("podkop-tweaker", "settings", "show_argon_tab", "0")
        local theme = require("podkop-tweaker.theme")
        local calls, result = {}, { current_version = "2.4.8-r2", latest_version = "3.0.0-r2" }
        theme.check = function(force) calls[#calls + 1] = force; return result end
        local ARG = H.reload("podkop-tweaker.api_argon")
        assert.equal(result, ARG.theme_check())
        for _, flag in ipairs({ false, "0", "true", 1, true, "1" }) do
            assert.equal(result, ARG.theme_check(flag))
        end
        assert.same({ false, false, false, false, false, true, true }, calls)
        assert.same({}, H.exec_cmds())
        assert.same({}, H.popen_cmds())
    end)

    it("fail-fasts legacy synchronous requests and forwards admitted async jobs without a tab guard", function()
        begin_argon({})
        require("luci.model.uci").cursor():set("podkop-tweaker", "settings", "show_argon_tab", "0")
        local worker = require("podkop-tweaker.theme_worker")
        local id, seen = string.rep("a", 32), {}
        local admitted = { success = true, queued = true, restart_id = id }
        worker.admit = function(value) seen[#seen + 1] = value; return admitted end
        local ARG = H.reload("podkop-tweaker.api_argon")
        -- Old 4.10.5 tabs send no async marker: fail fast instead of blocking.
        local legacy = ARG.theme_update(id)
        assert.is_false(legacy.success)
        assert.matches("Reload the Podkop Tweaker page", legacy.error, 1, true)
        assert.same({}, seen)
        assert.equal(admitted, ARG.theme_update({ async = "1", restart_id = id }))
        assert.same({ id }, seen)
        assert.same({}, H.execute_cmds())
    end)
end)

describe("api_argon checked typography writes", function()
    for _, action in ipairs({ "typography_save", "typography_reset", "reinject" }) do
        local endpoint = action
        for _, operation in ipairs({ "open", "read", "write", "close", "rename" }) do
            local fail = operation
            it(endpoint .. " preserves all live bytes on atomic " .. fail .. " failure", function()
                local path = fail == "rename" and CSS or CSS .. ".pt-typography.*"
                begin_argon({ failures = { [path] = { [fail] = true, partial = 2 } } })
                local original = ".base{}\n" .. MARKER_S .. "old" .. MARKER_E .. "\ntail{}\n"
                H.vfs_write(CSS, original)
                local resp = H.reload("podkop-tweaker.api_argon")[endpoint]({ font_size = "19" })
                assert.is_false(resp.success)
                assert.truthy(resp.error)
                assert.equal(endpoint ~= "reinject", resp.uci_saved)
                assert.is_false(resp.css_applied)
                if endpoint ~= "reinject" then assert.is_true(resp.partial) end
                assert.equal(original, H.vfs_read(CSS))
                no_css_stages()
            end)
        end
    end

    for _, action in ipairs({ "typography_save", "typography_reset" }) do
        it("reports a failed UCI commit before changing CSS in " .. action, function()
            begin_argon({})
            H.vfs_write(CSS, ".existing{}\n")
            local uci, reverts = require("luci.model.uci").cursor(), 0
            uci.commit = function() return false end
            uci.revert = function() reverts = reverts + 1; return true end
            local resp = H.reload("podkop-tweaker.api_argon")[action]({ font_size = "19" })
            assert.is_false(resp.success)
            assert.equal("Cannot commit Argon typography", resp.error)
            assert.equal(1, reverts)
            assert.equal(".existing{}\n", H.vfs_read(CSS))
        end)
    end

    for _, operation in ipairs({ "open", "read", "close" }) do
        local fail = operation
        for _, action in ipairs({ "typography_save", "typography_reset", "reinject" }) do
            local endpoint = action
            it(endpoint .. " stops on live CSS " .. fail .. " failure without truncating it", function()
                begin_argon({ failures = { [CSS] = { [fail] = true } } })
                local original = "pre\r\n" .. MARKER_S .. "old" .. MARKER_E .. "\r\ntail"
                H.vfs_write(CSS, original)
                local resp = H.reload("podkop-tweaker.api_argon")[endpoint]({ font_size = "19" })
                assert.is_false(resp.success)
                assert.truthy(resp.error)
                assert.is_nil(resp.stale)
                assert.is_false(resp.css_applied)
                assert.equal(endpoint ~= "reinject", resp.uci_saved)
                assert.equal(original, H.vfs_read(CSS))
                assert.same({}, css_stages())
                no_live_write()
            end)
        end
    end

    for _, action in ipairs({ "typography_save", "typography_reset", "reinject" }) do
        local endpoint = action
        it(endpoint .. " stops on UCI read failure without applying defaults", function()
            begin_argon({ failures = { [CONFIG] = { close = true } } })
            H.vfs_write(CSS, ".existing{}\n")
            local before = H.vfs_read(CONFIG)
            local resp = H.reload("podkop-tweaker.api_argon")[endpoint]({ font_size = "19" })
            assert.is_false(resp.success)
            assert.truthy(resp.error)
            assert.is_false(resp.uci_saved)
            assert.is_false(resp.css_applied)
            assert.is_nil(resp.partial)
            assert.equal(before, H.vfs_read(CONFIG))
            assert.equal(".existing{}\n", H.vfs_read(CSS))
            assert.same({}, H.commits())
            no_css_stages()
        end)

        it(endpoint .. " stops on a native package-read error before any UCI write", function()
            begin_argon({})
            H.vfs_write(CSS, ".existing{}\n")
            local before = H.vfs_read(CONFIG)
            require("luci.model.uci").cursor().get_all = function() return false, "Native UCI read failed" end
            local resp = H.reload("podkop-tweaker.api_argon")[endpoint]({ font_size = "19" })
            assert.is_false(resp.success)
            assert.equal("Native UCI read failed", resp.error)
            assert.is_false(resp.uci_saved)
            assert.is_false(resp.css_applied)
            assert.is_nil(resp.partial)
            assert.equal(before, H.vfs_read(CONFIG))
            assert.equal(".existing{}\n", H.vfs_read(CSS))
            assert.same({}, H.commits())
            no_css_stages()
        end)

        it(endpoint .. " retains unknown Argon fields and all Tweaker profile/color settings", function()
            begin_argon({ uci = {
                argon = {
                    H.sec("global", "global", { mode = "dark", future = "global value" }),
                    H.sec("typography", "typography", { font_size = "17", future = { "one", "two" } }),
                    H.sec("plugin", "unknown_plugin", { opaque = "keep" })
                },
                ["podkop-tweaker"] = { H.sec("appearance", "appearance", {
                    profile = "contrast", mono_font_size = "18", color_success_light = "#00aa11",
                    color_success_dark = "#22ff33", future = "keep" }) }
            } })
            local uci = require("luci.model.uci").cursor()
            local set = uci.set
            function uci:set(config, section, option, value)
                if config == "argon" and section == "typography" and value == nil then
                    error("An existing typography section must never be re-created")
                end
                return set(self, config, section, option, value)
            end
            H.vfs_write(CSS, "pre\n" .. MARKER_S .. "old" .. MARKER_E .. "\ntail")
            local resp = H.reload("podkop-tweaker.api_argon")[endpoint]({ font_size = "19" })
            assert.is_true(resp.success)
            assert.equal("dark", uci:get("argon", "global", "mode"))
            assert.equal("global value", uci:get("argon", "global", "future"))
            assert.same({ "one", "two" }, uci:get("argon", "typography", "future"))
            assert.equal("keep", uci:get("argon", "plugin", "opaque"))
            assert.equal("contrast", uci:get("podkop-tweaker", "appearance", "profile"))
            assert.equal("18", uci:get("podkop-tweaker", "appearance", "mono_font_size"))
            assert.equal("#00aa11", uci:get("podkop-tweaker", "appearance", "color_success_light"))
            assert.equal("#22ff33", uci:get("podkop-tweaker", "appearance", "color_success_dark"))
            assert.equal("keep", uci:get("podkop-tweaker", "appearance", "future"))
            assert.equal("1", uci:get("podkop-tweaker", "settings", "show_argon_tab"))
            no_css_stages()
        end)
    end

    it("reports a status-read failure after publication as applied but unverified", function()
        begin_argon({})
        H.vfs_write(CSS, ".theme{}\n")
        local srv = require("podkop-tweaker.services")
        local publish = srv.publish_file
        srv.publish_file = function(stage, target)
            local ok, err = publish(stage, target)
            if ok and target == CSS then H.state().failures[CSS] = { read = true } end
            return ok, err
        end
        local resp = H.reload("podkop-tweaker.api_argon").typography_save({ font_size = "19" })
        assert.is_false(resp.success)
        assert.is_true(resp.partial)
        assert.is_true(resp.uci_saved)
        assert.is_true(resp.css_applied)
        assert.is_true(resp.applied)
        assert.truthy(resp.error)
        assert.truthy(resp.stale_error)
        assert.is_nil(resp.stale)
        assert.truthy(H.vfs_read(CSS):find("19px", 1, true))
        no_css_stages()
    end)

    it("does not overwrite a stylesheet changed externally after staging", function()
        begin_argon({})
        H.vfs_write(CSS, "pre\n" .. MARKER_S .. "old" .. MARKER_E .. "\ntail")
        local srv = require("podkop-tweaker.services")
        local stage_file = srv.stage_file
        local external = ".new-theme{}\r\n.keep-all-of-this{}\n"
        srv.stage_file = function(target, bytes, options)
            local path, err = stage_file(target, bytes, options)
            if path and target == CSS then H.vfs_write(CSS, external) end
            return path, err
        end
        local resp = H.reload("podkop-tweaker.api_argon").typography_reset()
        assert.is_false(resp.success)
        assert.equal("Argon stylesheet changed during typography update", resp.error)
        assert.is_true(resp.uci_saved)
        assert.is_false(resp.css_applied)
        assert.is_true(resp.partial)
        assert.equal(external, H.vfs_read(CSS))
        no_css_stages()
    end)

    it("rejects a stage changed after its checked write", function()
        begin_argon({})
        local original = "pre\n" .. MARKER_S .. "old" .. MARKER_E .. "\ntail"
        H.vfs_write(CSS, original)
        local srv = require("podkop-tweaker.services")
        local stage_file = srv.stage_file
        srv.stage_file = function(target, bytes, options)
            local path, err = stage_file(target, bytes, options)
            if path and target == CSS then H.vfs_write(path, "unchecked competing bytes") end
            return path, err
        end
        local resp = H.reload("podkop-tweaker.api_argon").typography_reset()
        assert.is_false(resp.success)
        assert.truthy(resp.error)
        assert.is_true(resp.partial)
        assert.equal(original, H.vfs_read(CSS))
        no_css_stages()
    end)
end)

describe("Argon typography resource coordination", function()
    it("keeps the complete UCI/CSS mutation locked against a competing request", function()
        begin_argon({})
        H.vfs_write(CSS, ".theme{}\n")
        local ARG = H.reload("podkop-tweaker.api_argon")
        local srv = require("podkop-tweaker.services")
        local stage_file = srv.stage_file
        local competing
        local actor = coroutine.create(function() competing = ARG.typography_reset() end)
        srv.stage_file = function(target, bytes, options)
            if target == CSS then
                assert.equal("19", saved_uci().font_size)
                assert.is_true(H.vfs_exists(LOCK))
                local resumed, err = coroutine.resume(actor)
                assert.is_true(resumed, err)
                assert.is_false(competing.success)
                assert.truthy(competing.error)
                assert.equal("19", saved_uci().font_size)
            end
            return stage_file(target, bytes, options)
        end
        local resp = ARG.typography_save({ font_size = "19" })
        assert.is_true(resp.success)
        assert.equal("19", saved_uci().font_size)
        assert.truthy(H.vfs_read(CSS):find("19px", 1, true))
        assert.same({ "argon" }, H.commits())
        assert.is_false(H.vfs_exists(LOCK))
        no_css_stages()
    end)

    it("cleans only its own unique stage after a competing actor has staged another candidate", function()
        begin_argon({ failures = { [CSS] = { rename = true } } })
        local original = "pre\n" .. MARKER_S .. "old" .. MARKER_E .. "\ntail"
        H.vfs_write(CSS, original)
        local srv = require("podkop-tweaker.services")
        local other_stage
        local actor = coroutine.create(function()
            other_stage = assert(srv.stage_file(CSS, "other actor's checked bytes", { suffix = ".pt-typography" }))
            coroutine.yield()
            srv.discard_stage(other_stage)
            assert.is_false(H.vfs_exists(other_stage))
        end)
        local resumed, err = coroutine.resume(actor)
        assert.is_true(resumed, err)
        local resp = H.reload("podkop-tweaker.api_argon").typography_reset()
        assert.is_false(resp.success)
        assert.equal(original, H.vfs_read(CSS))
        assert.equal("other actor's checked bytes", H.vfs_read(other_stage))
        local stages = css_stages()
        assert.equal(2, #stages)
        assert.are_not.equal(stages[1], stages[2])
        resumed, err = coroutine.resume(actor)
        assert.is_true(resumed, err)
        assert.equal("dead", coroutine.status(actor))
        no_css_stages()
    end)

    it("surfaces lock release failure after a disk-applied reset", function()
        begin_argon({ failures = { [LOCK] = { rmdir = true } } })
        H.vfs_write(CSS, "pre\n" .. MARKER_S .. "old" .. MARKER_E .. "\ntail")
        local resp = H.reload("podkop-tweaker.api_argon").typography_reset()
        assert.is_false(resp.success)
        assert.truthy(resp.error)
        assert.is_true(resp.partial)
        assert.is_true(resp.applied)
        assert.is_true(resp.uci_saved)
        assert.is_true(resp.css_applied)
        assert.is_true(resp.unknown)
        assert.equal(resp.error, resp.lock_error)
        assert.is_nil(resp.stale)
        assert.equal("pre\n\ntail", H.vfs_read(CSS))
        assert.is_true(H.vfs_exists(LOCK), "failed lock cleanup is retained for inspection")
        no_css_stages()
    end)

    it("reports release uncertainty after CSS-only reinjection without inventing a UCI save", function()
        begin_argon({ failures = { [LOCK] = { rmdir = true } } })
        H.vfs_write(CSS, ".theme{}\n")
        local resp = H.reload("podkop-tweaker.api_argon").reinject()
        assert.is_false(resp.success)
        assert.is_true(resp.unknown)
        assert.is_false(resp.uci_saved)
        assert.is_true(resp.css_applied)
        assert.is_true(resp.partial)
        assert.is_true(resp.applied)
        assert.is_nil(resp.stale)
        assert.truthy(H.vfs_read(CSS):find(MARKER_S, 1, true))
        assert.same({}, H.commits())
        no_css_stages()
    end)

    for _, first_run in ipairs({ false, true }) do
        local missing = first_run
        it("serves checked read observations even while a failed lock release is retained: " .. tostring(missing), function()
            begin_argon({ failures = { [LOCK] = { rmdir = true } },
                uci = { argon = { H.sec("typography", "typography", { font_size = "19" }) } } })
            if missing then os.remove(CONFIG); H.state().uci.argon = nil end
            H.vfs_write(CSS, ".theme{}\n" .. MARKER_S .. "existing" .. MARKER_E)
            local resp = H.reload("podkop-tweaker.api_argon").typography()
            -- 4.11.0: read-only observations no longer take the exclusive
            -- writer lock, so a retained release failure cannot block them.
            assert.is_nil(resp.error)
            assert.is_nil(resp.unknown)
            assert.truthy(resp.settings)
            assert.is_false(resp.stale)
            assert.equal(missing and "defaults" or "uci", resp.settings_source)
            assert.equal(missing, resp.config_missing)
            assert.same({}, H.commits())
            no_live_write()
        end)
    end

    it("typography returns the complete primary read error without lock uncertainty", function()
        begin_argon({})
        local original = ".theme{}\n"
        H.vfs_write(CSS, original)
        local primary = "Primary native UCI read failure\n" .. string.rep("complete diagnostic <not HTML>\n", 1000)
        require("luci.model.uci").cursor().get_all = function() return nil, primary end
        local resp = H.reload("podkop-tweaker.api_argon").typography()
        assert.truthy(resp.error)
        assert.equal(primary, resp.error)
        assert.is_nil(resp.unknown)
        assert.is_nil(resp.lock_error)
        assert.is_nil(resp.settings)
        assert.is_nil(resp.stale)
        assert.equal(original, H.vfs_read(CSS))
        assert.same({}, H.commits())
    end)

    for _, action in ipairs({ "typography_save", "typography_reset", "reinject" }) do
        local endpoint = action
        it(endpoint .. " preserves a complete primary read error and adds release uncertainty without applied proof", function()
            begin_argon({ failures = { [LOCK] = { rmdir = true } } })
            local original = ".theme{}\n"
            H.vfs_write(CSS, original)
            local primary = "Primary native UCI read failure\n" .. string.rep("complete diagnostic <not HTML>\n", 1000)
            require("luci.model.uci").cursor().get_all = function() return nil, primary end
            local resp = H.reload("podkop-tweaker.api_argon")[endpoint]({ font_size = "19" })
            assert.is_false(resp.success)
            assert.is_true(resp.unknown)
            assert.equal(primary, resp.error)
            assert.truthy(resp.lock_error)
            assert.are_not.equal(primary, resp.lock_error)
            assert.is_nil(resp.settings)
            assert.is_nil(resp.stale)
            assert.is_nil(resp.partial)
            assert.is_nil(resp.applied)
            assert.falsy(resp.uci_saved)
            assert.falsy(resp.css_applied)
            assert.equal(original, H.vfs_read(CSS))
            assert.same({}, H.commits())
            no_css_stages()
        end)
    end

    for _, action in ipairs({ "typography_save", "typography_reset" }) do
        local endpoint = action
        it(endpoint .. " keeps the primary commit error and full details when release also fails", function()
            begin_argon({ failures = { [LOCK] = { rmdir = true } } })
            local original = ".theme{}\n"
            H.vfs_write(CSS, original)
            local details = string.rep("complete native commit diagnostic <plain text>\n", 1000)
            require("luci.model.uci").cursor().commit = function() return false, details end
            local resp = H.reload("podkop-tweaker.api_argon")[endpoint]({ font_size = "19" })
            assert.is_false(resp.success)
            assert.is_true(resp.unknown)
            assert.equal("Cannot commit Argon typography", resp.error)
            assert.equal(details, resp.details)
            assert.truthy(resp.lock_error)
            assert.is_false(resp.uci_saved)
            assert.is_false(resp.css_applied)
            assert.is_nil(resp.partial)
            assert.is_nil(resp.applied)
            assert.is_nil(resp.settings)
            assert.is_nil(resp.stale)
            assert.equal(original, H.vfs_read(CSS))
            no_css_stages()
        end)
    end

    it("retains a complete CSS publication error beside release uncertainty after a confirmed UCI save", function()
        begin_argon({ failures = { [LOCK] = { rmdir = true } } })
        local original = ".theme{}\n" .. MARKER_S .. "old" .. MARKER_E .. "\n.tail{}"
        H.vfs_write(CSS, original)
        local primary = "Primary CSS publication failure\n" .. string.rep("full publisher diagnostic\n", 1000)
        require("podkop-tweaker.services").publish_file = function() return false, primary end
        local resp = H.reload("podkop-tweaker.api_argon").typography_save({ font_size = "19" })
        assert.is_false(resp.success)
        assert.is_true(resp.unknown)
        assert.equal(primary, resp.error)
        assert.truthy(resp.lock_error)
        assert.are_not.equal(primary, resp.lock_error)
        assert.is_true(resp.uci_saved)
        assert.is_false(resp.css_applied)
        assert.is_true(resp.partial)
        assert.is_true(resp.applied)
        assert.is_nil(resp.stale)
        assert.equal(original, H.vfs_read(CSS))
        no_css_stages()
    end)

    it("keeps low-level write release uncertainty distinct from an applied result", function()
        begin_argon({ failures = { [LOCK] = { rmdir = true } } })
        local original = ".theme{}\n" .. MARKER_S .. "incomplete"
        H.vfs_write(CSS, original)
        local ok, err, uncertain, info = require("podkop-tweaker.argon").remove_css()
        assert.is_false(ok)
        assert.equal("Incomplete or duplicate Argon typography CSS markers", err)
        assert.is_true(uncertain)
        assert.is_true(info.unknown)
        assert.truthy(info.lock_error)
        assert.is_nil(info.applied)
        assert.is_nil(info.partial)
        assert.equal(original, H.vfs_read(CSS))
        assert.same({}, H.commits())
        no_css_stages()
    end)

    it("preserves a low-level checked read error without lock uncertainty", function()
        begin_argon({})
        local primary = "Primary package read failure\n" .. string.rep("full read diagnostic\n", 1000)
        require("luci.model.uci").cursor().get_all = function() return false, primary end
        local settings, err, uncertain, info = require("podkop-tweaker.argon").read_settings()
        assert.is_nil(settings)
        assert.equal(primary, err)
        assert.is_nil(uncertain, "an unlocked observation never reports release uncertainty")
        assert.is_nil(info)
        assert.same({}, H.commits())
    end)

    it("serves read observations while a foreign writer lock blocks only mutations", function()
        begin_argon({})
        H.vfs_mkdir(LOCK)
        H.vfs_write(CSS, ".theme{}\n")
        local before = H.vfs_read(CONFIG)
        local ARG = H.reload("podkop-tweaker.api_argon")
        local read, reset = ARG.typography(), ARG.typography_reset()
        assert.is_nil(read.error)
        assert.truthy(read.settings)
        assert.is_true(read.stale)
        assert.is_nil(read.unknown)
        assert.is_false(reset.success)
        assert.truthy(reset.error)
        assert.is_nil(reset.unknown)
        assert.is_nil(reset.partial)
        assert.equal(before, H.vfs_read(CONFIG))
        assert.equal(".theme{}\n", H.vfs_read(CSS))
        assert.same({}, H.commits())
        assert.is_true(H.vfs_exists(LOCK), "a foreign lock is never removed or stolen")
        no_css_stages()
    end)
end)
