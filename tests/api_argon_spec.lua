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

describe("api_argon theme (version / check / update)", function()
    local CACHE = "/tmp/pt_argon_theme_check.json"
    local APK_RESP = { match = "apk list --installed", out = "luci-theme-argon-2.4.6-r1 [installed]\n" }
    local OPKG_RESP = { match = "opkg list-installed", out = "luci-theme-argon - 2.4.6-r1\n" }
    local GH_LATEST = '{"tag_name":"v2.4.7","assets":[' ..
        '{"name":"luci-app-argon-config-2.4.7-r1.apk","browser_download_url":"https://github.com/jerrykuku/luci-theme-argon/releases/download/v2.4.7/luci-app-argon-config-2.4.7-r1.apk"},' ..
        '{"name":"luci-theme-argon-2.4.7-r1.apk","browser_download_url":"https://github.com/jerrykuku/luci-theme-argon/releases/download/v2.4.7/luci-theme-argon-2.4.7-r1.apk"},' ..
        '{"name":"luci-theme-argon_2.4.7_all.ipk","browser_download_url":"https://github.com/jerrykuku/luci-theme-argon/releases/download/v2.4.7/luci-theme-argon_2.4.7_all.ipk"}]}'
    local GH_RESP = { match = "api.github.com/repos/jerrykuku", out = GH_LATEST }

    local function mod(opts)
        begin_argon(opts or {})
        return H.reload("podkop-tweaker.api_argon")
    end

    it("installed_version: apk format, opkg fallback, absent", function()
        begin_argon({ sys = { APK_RESP } })
        assert.equal("2.4.6", require("podkop-tweaker.theme").installed_version())
        H.finish()
        begin_argon({ sys = { OPKG_RESP } })
        assert.equal("2.4.6", require("podkop-tweaker.theme").installed_version())
        H.finish()
        begin_argon({})
        assert.is_nil(require("podkop-tweaker.theme").installed_version())
    end)

    it("check: fresh cache served without network; expired cache refetched", function()
        local ARG = mod({ sys = { APK_RESP, GH_RESP } })
        H.vfs_write(CACHE, '{"latest_version":"2.4.5","current_version":"2.4.6","update_available":false,"cached_at":' .. os.time() .. '}')
        local r = ARG.theme_check(false)
        assert.equal("2.4.5", r.latest_version)
        assert.is_false(r.update_available)
        for _, c in ipairs(H.exec_cmds()) do
            assert.falsy(c:find("api.github.com", 1, true), "network hit with fresh cache")
        end

        H.finish()
        local ARG2 = mod({ sys = { APK_RESP, GH_RESP } })
        H.vfs_write(CACHE, '{"latest_version":"2.4.5","cached_at":' .. (os.time() - 90000) .. '}')
        local r2 = ARG2.theme_check(false)
        assert.equal("2.4.7", r2.latest_version)
        assert.is_true(r2.update_available)
        assert.truthy(H.vfs_read(CACHE):find("2.4.7", 1, true))
    end)

    it("check: force bypasses fresh cache; rate limit surfaced", function()
        local ARG = mod({ sys = { APK_RESP, GH_RESP } })
        H.vfs_write(CACHE, '{"latest_version":"2.4.5","cached_at":' .. os.time() .. '}')
        local r = ARG.theme_check(true)
        assert.equal("2.4.7", r.latest_version)

        H.finish()
        local ARG2 = mod({ sys = { APK_RESP,
            { match = "api.github.com/repos/jerrykuku", out = '{"message":"API rate limit exceeded"}' } } })
        assert.equal("GitHub API rate limit exceeded", ARG2.theme_check(true).error)
    end)

    it("check: both asset URLs picked by name pattern", function()
        local r = mod({ sys = { APK_RESP, GH_RESP } }).theme_check(true)
        assert.matches("luci%-theme%-argon%-2%.4%.7%-r1%.apk$", r.download_url_apk)
        assert.matches("luci%-theme%-argon_2%.4%.7_all%.ipk$", r.download_url_ipk)
    end)

    it("update: theme not installed -> exact error", function()
        assert.same({ error = "Argon theme is not installed" }, mod({}).theme_update())
    end)

    it("update: download miss -> error, theme untouched", function()
        local ARG = mod({ sys = { APK_RESP, GH_RESP } })
        assert.same({ error = "Failed to download theme package" }, ARG.theme_update())
    end)

    it("update: happy apk flow — snapshot saved, installed, typography restored, css reinjected, caches cleared", function()
        local ARG = mod({
            sys = {
                APK_RESP,
                GH_RESP,
                { match = "apk add", out = "OK\nEXIT:0" }
            },
            uci = {
                argon = { H.sec("typography", "typography", { font_size = "17", font_weight = "550" }) }
            }
        })
        H.vfs_write(CSS, ".base{}\n")
        H.vfs_write("/tmp/pt-argon-theme/theme.apk", "package-bytes")
        local r = ARG.theme_update()
        assert.is_true(r.success)
        assert.equal("2.4.6", r.new_version)
        -- typography snapshot survived the update
        local uci = require("luci.model.uci").cursor()
        assert.equal("17", uci:get("argon", "typography", "font_size"))
        assert.equal("550", uci:get("argon", "typography", "font_weight"))
        -- CSS block reinjected into the fresh cascade.css
        local css = H.vfs_read(CSS)
        assert.truthy(css:find("Podkop Tweaker Typography", 1, true))
        assert.truthy(css:find("font%-size: 17px"))
        -- Caches cleared and delayed restart queued after installation.
        local saw_luci_rm, saw_uhttpd = false, false
        for _, c in ipairs(H.execute_cmds()) do
            if c:find("rm -rf /tmp/luci-", 1, true) then saw_luci_rm = true end
        end
        for _, c in ipairs(H.exec_cmds()) do
            if c:find("sleep 1; /etc/init.d/uhttpd restart", 1, true) then saw_uhttpd = true end
        end
        assert.truthy(saw_luci_rm)
        assert.truthy(saw_uhttpd)
        -- install ran with the cd / prefix (hook cwd safety) and the apk asset path
        local saw_install = false
        for _, c in ipairs(H.exec_cmds()) do
            if c:find("cd / && apk add --allow-untrusted /tmp/pt-argon-theme/theme.apk", 1, true) then saw_install = true end
        end
        assert.truthy(saw_install)
    end)

    it("update: hook noise (EXIT:1) with updated version -> oracle success, restore still runs", function()
        local calls = 0
        local SEQ_RESP = {
            match = "apk list --installed",
            out = function()
                calls = calls + 1
                -- detect (2.4.6) -> check entry (2.4.6) -> oracle after install (2.4.7)
                if calls >= 3 then
                    return "luci-theme-argon-2.4.7-r1 [installed]\n"
                end
                return "luci-theme-argon-2.4.6-r1 [installed]\n"
            end
        }
        local ARG = mod({
            sys = {
                SEQ_RESP,
                GH_RESP,
                { match = "apk add", out = "Executing luci-theme-argon-2.4.7-r1.post-upgrade\n* fchdir: Not a directory\nEXIT:1" }
            },
            uci = {
                argon = { H.sec("typography", "typography", { font_size = "18" }) }
            }
        })
        H.vfs_write(CSS, ".base{}\n")
        H.vfs_write("/tmp/pt-argon-theme/theme.apk", "package-bytes")
        local r = ARG.theme_update()
        assert.is_true(r.success)
        assert.equal("2.4.7", r.new_version)
        -- restore flow completed despite the failed hook
        local uci = require("luci.model.uci").cursor()
        assert.equal("18", uci:get("argon", "typography", "font_size"))
        assert.truthy(H.vfs_read(CSS):find("font%-size: 18px"))
        local saw_luci_rm = false
        for _, c in ipairs(H.execute_cmds()) do
            if c:find("rm -rf /tmp/luci-", 1, true) then saw_luci_rm = true end
        end
        assert.truthy(saw_luci_rm)
    end)

    it("update: install failure -> error surfaced", function()
        local ARG = mod({
            sys = {
                APK_RESP,
                GH_RESP,
                { match = "apk add", out = "ERROR: unable to install\nEXIT:1" }
            }
        })
        H.vfs_write("/tmp/pt-argon-theme/theme.apk", "pkg")
        local r = ARG.theme_update()
        assert.is_false(r.success)
        assert.equal("Theme package installation failed", r.error)
        assert.matches("unable to install", r.details)
    end)

    it("update: dependency conflict preserves complete output and does not restart services", function()
        local details = "ERROR: unable to select packages:\n" ..
            "  ucode-2026.01.16~85922056-r1:\n" ..
            "    breaks: luci-theme-argon-2.4.8-r1[ucode>=2026.02.27]\n" ..
            string.rep("    satisfies: firewall4[ucode>=2022.03.22]\n", 80) ..
            "dependency-output-end"
        local ARG = mod({
            sys = {
                { match = "apk list --installed", out = "luci-theme-argon-2.4.7-r1 [installed]\n" },
                { match = "api.github.com/repos/jerrykuku", out = GH_LATEST:gsub("2%.4%.7", "2.4.8") },
                { match = "apk add", out = details .. "\nEXIT:1" }
            },
            uci = { argon = { H.sec("typography", "typography", { font_size = "18" }) } }
        })
        H.vfs_write(CSS, ".existing-typography{}\n")
        H.vfs_write("/tmp/pt-argon-theme/theme.apk", "pkg")
        local r = ARG.theme_update()
        assert.is_false(r.success)
        assert.equal("Theme package installation failed", r.error)
        assert.equal(details, r.details)
        assert.equal(".existing-typography{}\n", H.vfs_read(CSS))
        assert.equal("18", saved_uci().font_size)
        for _, cmd in ipairs(H.execute_cmds()) do
            assert.falsy(cmd:find("uhttpd restart", 1, true))
        end
    end)

    it("update: already up to date -> exact error", function()
        local ARG = mod({
            sys = {
                { match = "apk list --installed", out = "luci-theme-argon-2.4.7-r1 [installed]\n" },
                GH_RESP
            }
        })
        assert.same({ error = "Theme is already up to date" }, ARG.theme_update())
    end)
end)
