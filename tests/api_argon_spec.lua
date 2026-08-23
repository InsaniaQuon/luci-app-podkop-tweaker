-- api_argon_spec | v1.0.0 | 23.08.2026 | Max-coverage specs for V2 pure handlers of api_argon

package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path

local H = require("pt_harness")

local CSS = "/www/luci-static/argon/css/cascade.css"
local MARKER_S = "/* === Podkop Tweaker Typography === */"
local MARKER_E = "/* === End Podkop Tweaker Typography === */"

local function begin_argon(opts)
    H.begin(opts)
    local LIB = require("podkop-tweaker.lib")
    LIB.ARGON_CASCADE_CSS = CSS
    local uci = require("luci.model.uci").cursor()
    uci:set("podkop-tweaker", "settings", "show_argon_tab", "1")
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
        assert.same({ "Arial", "Google Sans", "Tahoma", "Verdana", "monospace", "system-ui" },
            resp.font_families)
    end)

    it("reports stale when css missing or without marker", function()
        begin_argon({})
        local ARG = H.reload("podkop-tweaker.api_argon")
        assert.is_true(ARG.typography().stale)
        H.vfs_write(CSS, "plain css without markers\n")
        assert.is_true(ARG.typography().stale)
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

    it("apply failure -> success=false, stale=true", function()
        begin_argon({})
        local ARG = H.reload("podkop-tweaker.api_argon")
        local resp = ARG.typography_save({ font_size = "15" })
        assert.is_false(resp.success)
        assert.is_true(resp.stale)
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
        -- V1 semantics of remove_css: only pre-block content survives
        assert.falsy(css:find("tail", 1, true))
        assert.truthy(css:find("pre", 1, true))
    end)

    it("missing css file still succeeds", function()
        begin_argon({})
        local ARG = H.reload("podkop-tweaker.api_argon")
        local resp = ARG.typography_reset()
        assert.is_true(resp.success)
        assert.is_true(resp.stale)
    end)
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
        assert.is_true(resp.stale)
    end)

    it("enable_tab helper flips flag back on", function()
        begin_argon({})
        local ARG = H.reload("podkop-tweaker.api_argon")
        local uci = require("luci.model.uci").cursor()
        uci:set("podkop-tweaker", "settings", "show_argon_tab", "0")
        assert.same({ error = "Argon tab is disabled" }, ARG.reinject())
        enable_tab()
        local resp = ARG.reinject()
        assert.falsy(resp.error)
    end)
end)
