-- HTTP transport regression specs: streaming multipart, CSRF, parser failures.
package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path

local H = require("pt_harness")
local CTRL = "luci.controller.podkop-tweaker"
local TOKEN = string.rep("c", 64)
local NAME = "luci-app-podkop-tweaker-v4.5.1.tar.gz"
local function with_colors(settings)
    local result = {
        color_success_light = "#00be00", color_error_light = "#ff0000", color_warning_light = "#ff8c42",
        color_success_dark = "#00ff00", color_error_dark = "#ff8080", color_warning_dark = "#ffbd42"
    }
    for key, value in pairs(settings) do result[key] = value end
    return result
end

after_each(function()
    H.finish()
    package.loaded[CTRL] = nil
end)

describe("page theme context", function()
    local function render(uci)
        H.begin({ uci = uci })
        package.loaded[CTRL] = nil
        local ctl = require(CTRL)
        local vars
        luci.template = { render = function(_, input) vars = input end }
        ctl.action_about()
        return vars
    end

    it("reads mode from the first global section, including anonymous Argon sections", function()
        local vars = render({
            luci = { H.sec("main", "core", { mediaurlbase = "/luci-static/argon" }) },
            argon = { H.sec("cfg123", "global", { mode = "dark" }) }
        })
        assert.equal("argon", vars.pt_theme)
        assert.equal("dark", vars.pt_theme_mode)
    end)

    it("normalizes invalid modes instead of injecting configuration into markup", function()
        local vars = render({
            luci = { H.sec("main", "core", { mediaurlbase = "/luci-static/argon" }) },
            argon = { H.sec("cfg123", "global", { mode = '<script>' }) }
        })
        assert.equal("normal", vars.pt_theme_mode)
    end)

    it("does not use leftover Argon settings while another theme is active", function()
        local vars = render({
            luci = { H.sec("main", "core", { mediaurlbase = "/luci-static/bootstrap" }) },
            argon = { H.sec("cfg123", "global", { mode = "dark" }) }
        })
        assert.equal("bootstrap", vars.pt_theme)
        assert.equal("", vars.pt_theme_mode)
    end)

    it("supplies normalized app appearance even when the Argon tab is hidden", function()
        local vars = render({
            ["podkop-tweaker"] = {
                H.sec("settings", "settings", { show_argon_tab = "0" }),
                H.sec("appearance", "appearance", { profile = "contrast", mono_font_size = '18" bad="1', mono_font_weight = "500", mono_line_height = "1.8" })
            }
        })
        assert.is_false(vars.show_argon)
        assert.same(with_colors({ profile = "contrast", mono_font_size = "13", mono_font_weight = "500", mono_line_height = "1.8" }), vars.pt_appearance)
    end)

    it("normalizes color values before including them in page attributes", function()
        local vars = render({ ["podkop-tweaker"] = { H.sec("appearance", "appearance", {
            color_success_dark = '#112233\" data-bad=\"x', color_warning_dark = "#AABBCC"
        }) } })
        assert.equal("#00ff00", vars.pt_appearance.color_success_dark)
        assert.equal("#aabbcc", vars.pt_appearance.color_warning_dark)
    end)
    it("uses only a bounded hexadecimal reload nonce for equal-version asset refresh", function()
        H.begin({ fv = { _pt_reload = string.rep("a", 32) } })
        package.loaded[CTRL] = nil
        local vars
        luci.template = { render = function(_, input) vars = input end }
        require(CTRL).action_about()
        assert.equal(vars.app_version .. "-" .. string.rep("a", 32), vars.asset_version)
        H.state().fv._pt_reload = '\" onclick=\"bad'
        require(CTRL).action_about()
        assert.equal(vars.app_version, vars.asset_version)
    end)
end)

describe("appearance HTTP adapter", function()
    it("passes appearance and all six colors through the CSRF-protected save endpoint", function()
        H.begin({ uci = { ["podkop-tweaker"] = { H.sec("settings", "settings", { show_argon_tab = "1" }) } },
            fv = { token = TOKEN, profile = "contrast", mono_font_size = "16", mono_font_weight = "500", mono_line_height = "1.7",
                color_success_light = "#004400", color_error_light = "#aa0000", color_warning_light = "#884400",
                color_success_dark = "#11FF22", color_error_dark = "#ff8899", color_warning_dark = "#ffcc11" } })
        H.vfs_write("/etc/podkop-tweaker.token", TOKEN)
        package.loaded[CTRL] = nil
        require(CTRL).api_tweaker_appearance_save()
        assert.is_true(H.last_json().success)
        assert.same({ profile = "contrast", mono_font_size = "16", mono_font_weight = "500", mono_line_height = "1.7",
            color_success_light = "#004400", color_error_light = "#aa0000", color_warning_light = "#884400",
            color_success_dark = "#11ff22", color_error_dark = "#ff8899", color_warning_dark = "#ffcc11" }, H.last_json().settings)
    end)

    it("rejects save and reset without a valid token, with no settings writes", function()
        H.begin({ uci = { ["podkop-tweaker"] = { H.sec("settings", "settings", { show_argon_tab = "1" }) } },
            fv = { token = "wrong", profile = "contrast" } })
        H.vfs_write("/etc/podkop-tweaker.token", TOKEN)
        package.loaded[CTRL] = nil
        local ctl = require(CTRL)
        ctl.api_tweaker_appearance_save()
        ctl.api_tweaker_appearance_reset()
        ctl.api_tweaker_appearance_colors_reset()
        assert.equal(403, H.http()._status[1].code)
        assert.same({}, H.commits())
    end)
end)

describe("local reinstall HTTP adapter", function()
    it("forwards the reinstall flag only after the app CSRF check", function()
        H.begin({ fv = { token = TOKEN, reinstall = "1" } })
        H.vfs_write("/etc/podkop-tweaker.token", TOKEN)
        package.loaded[CTRL] = nil
        local ctl = require(CTRL)
        local received
        require("podkop-tweaker.api_update").apply = function(flag) received = flag; return { success = true, reinstalled = true } end
        ctl.api_apply_update()
        assert.equal("1", received)
        assert.is_true(H.last_json().reinstalled)
    end)
    it("invalid CSRF prevents invoking apply even with reinstall=1", function()
        H.begin({ fv = { token = "invalid", reinstall = "1" } })
        H.vfs_write("/etc/podkop-tweaker.token", TOKEN)
        package.loaded[CTRL] = nil
        local ctl = require(CTRL)
        local called = false
        require("podkop-tweaker.api_update").apply = function() called = true end
        ctl.api_apply_update()
        assert.is_false(called)
        assert.equal(403, H.http()._status[1].code)
    end)
end)

local function begin_upload(opts)
    opts = opts or {}
    H.begin({
        env = { CONTENT_TYPE = opts.legacy and "application/x-www-form-urlencoded" or "multipart/form-data; boundary=test" },
        fv = { token = opts.token or TOKEN, file_data = "old-base64", file_name = NAME }
    })
    H.vfs_write("/etc/podkop-tweaker.token", TOKEN)
    local http = H.http()
    local callback, parsed
    local original_formvalue = http.formvalue
    http.setfilehandler = function(fn)
        assert.falsy(parsed, "file handler must be registered before parsing")
        callback = fn
    end
    http.formvalue = function(key)
        if not parsed then
            parsed = true
            if opts.parse_error then error(opts.parse_error) end
            if not opts.legacy then
                assert.is_function(callback)
                for _, part in ipairs(opts.parts or {}) do
                    local meta = { name = part.name or "archive", file = part.filename or NAME }
                    for _, chunk in ipairs(part.chunks or {}) do callback(meta, chunk, false) end
                    if not part.incomplete then callback(meta, "", true) end
                end
            end
        end
        return original_formvalue(key)
    end
    local UPD = require("podkop-tweaker.api_update")
    local received = {}
    UPD.upload_binary = function(data, name)
        received.data, received.name = data, name
        return { success = true }
    end
    UPD.upload = function(data, name)
        received.legacy, received.name = data, name
        return { success = true }
    end
    package.loaded[CTRL] = nil
    return require(CTRL), received, UPD
end

describe("Local Update multipart transport", function()
    it("joins binary chunks without base64 and preserves filename", function()
        local bytes = "\31\139" .. string.rep("\0\255", 55000)
        local ctl, received = begin_upload({ parts = { { chunks = { bytes:sub(1, 4096), bytes:sub(4097) } } } })
        ctl.api_upload_update()
        assert.same({ success = true }, H.last_json())
        assert.equal(bytes, received.data)
        assert.equal(NAME, received.name)
    end)

    it("invalid token prevents processing or writing an archive", function()
        local ctl, received = begin_upload({ token = "wrong", parts = { { chunks = { "archive" } } } })
        ctl.api_upload_update()
        assert.equal("CSRF token mismatch", H.last_json().error)
        assert.equal(403, H.http()._status[1].code)
        assert.is_nil(received.data)
        assert.falsy(H.vfs_exists("/tmp/pt-update/upload.tar.gz"))
    end)

    it("oversized streamed file is rejected before archive processing", function()
        local ctl, received, UPD = begin_upload({ parts = { { chunks = { string.rep("x", 128001) } } } })
        ctl.api_upload_update()
        assert.equal("Archive too large (max " .. UPD.UPLOAD_MAX_SIZE .. " bytes)", H.last_json().error)
        assert.is_nil(received.data)
    end)

    it("missing file returns a JSON error", function()
        local ctl, received = begin_upload({})
        ctl.api_upload_update()
        assert.equal("No file uploaded", H.last_json().error)
        assert.is_nil(received.data)
    end)

    it("truncated multipart file is not passed to the archive validator", function()
        local ctl, received = begin_upload({ parts = { { chunks = { "partial" }, incomplete = true } } })
        ctl.api_upload_update()
        assert.equal("Incomplete archive upload", H.last_json().error)
        assert.is_nil(received.data)
    end)

    it("multiple archive parts are rejected", function()
        local ctl, received = begin_upload({ parts = { { chunks = { "first" } }, { chunks = { "second" } } } })
        ctl.api_upload_update()
        assert.equal("Only one update archive is allowed", H.last_json().error)
        assert.is_nil(received.data)
    end)

    it("parser exceptions become HTTP 400 with full JSON diagnostics, not HTTP 500", function()
        local ctl, received = begin_upload({ legacy = true, parse_error = "POST data exceeds maximum allowed length" })
        ctl.api_upload_update()
        assert.equal(400, H.http()._status[1].code)
        assert.equal("Cannot read update request", H.last_json().error)
        assert.matches("POST data exceeds maximum allowed length", H.last_json().details)
        assert.is_nil(received.data)
    end)

    it("retains the existing base64 API for older clients", function()
        local ctl, received = begin_upload({ legacy = true })
        ctl.api_upload_update()
        assert.same({ success = true }, H.last_json())
        assert.equal("old-base64", received.legacy)
        assert.equal(NAME, received.name)
    end)
end)
