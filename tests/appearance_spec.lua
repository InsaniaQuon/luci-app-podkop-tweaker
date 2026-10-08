-- appearance_spec | v2.0.0 | 08.10.2026 | Color validation, independent resets and persistence
package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path
local H = require("pt_harness")
local COLORS = {
    color_success_light = "#00be00", color_error_light = "#ff0000", color_warning_light = "#ff8c42",
    color_success_dark = "#00ff00", color_error_dark = "#ff8080", color_warning_dark = "#ffbd42"
}
local function with_colors(settings)
    local result = {}
    for key, value in pairs(COLORS) do result[key] = value end
    for key, value in pairs(settings) do result[key] = value end
    return result
end
local DEFAULTS = with_colors({ profile = "soft", mono_font_size = "13", mono_font_weight = "400", mono_line_height = "1.6" })

after_each(function() H.finish() end)

local function begin(settings, enabled)
    H.begin({ uci = {
        ["podkop-tweaker"] = {
            H.sec("settings", "settings", { show_argon_tab = enabled == false and "0" or "1" }),
            H.sec("appearance", "appearance", settings)
        }
    } })
    return require("podkop-tweaker.api_argon")
end

describe("Tweaker appearance", function()
    it("uses soft defaults without creating configuration on a read", function()
        local api = begin({})
        assert.same(DEFAULTS, api.appearance().settings)
        assert.same({}, H.commits())
    end)

    it("reads persisted app settings without consulting global typography", function()
        local saved = with_colors({ profile = "contrast", mono_font_size = "18", mono_font_weight = "500", mono_line_height = "1.8" })
        local api = begin(saved)
        require("luci.model.uci").cursor():set("argon", "typography", "font_size", "20")
        assert.same(saved, api.appearance().settings)
    end)

    it("normalizes malformed UCI values independently before page rendering", function()
        begin({ profile = 'dark" onclick="bad', mono_font_size = "99px;}", mono_font_weight = {}, mono_line_height = "1.3" })
        assert.same(with_colors({ profile = "soft", mono_font_size = "13", mono_font_weight = "400", mono_line_height = "1.3" }),
            require("podkop-tweaker.appearance").read())
    end)

    it("saves only the appearance section; global typography/CSS and visibility survive", function()
        local api = begin({})
        local uci = require("luci.model.uci").cursor()
        uci:set("argon", "typography", "font_weight", "650")
        H.vfs_write("/www/luci-static/argon/css/cascade.css", "unchanged CSS")
        local settings = with_colors({ profile = "contrast", mono_font_size = "12", mono_font_weight = "500", mono_line_height = "1.3" })
        assert.same({ success = true, settings = settings }, api.appearance_save(settings))
        assert.same(settings, require("podkop-tweaker.appearance").read())
        assert.same({ "podkop-tweaker" }, H.commits())
        assert.equal("1", uci:get("podkop-tweaker", "settings", "show_argon_tab"))
        assert.equal("650", uci:get("argon", "typography", "font_weight"))
        assert.equal("unchanged CSS", H.vfs_read("/www/luci-static/argon/css/cascade.css"))
    end)

    it("merges partial API updates with stored values", function()
        local api = begin({ profile = "contrast", mono_font_size = "17", mono_font_weight = "500", mono_line_height = "1.8" })
        local resp = api.appearance_save({ mono_font_size = "14", ignored = "x" })
        assert.same(with_colors({ profile = "contrast", mono_font_size = "14", mono_font_weight = "500", mono_line_height = "1.8" }), resp.settings)
    end)

    for _, payload in ipairs({
        { profile = "neon" }, { mono_font_size = "11" }, { mono_font_size = "19" },
        { mono_font_size = "13.5" }, { mono_font_size = "14; color:red" },
        { mono_font_weight = "600" }, { mono_line_height = "1.9" }, { mono_line_height = "1.35" },
        { profile = {} }
    }) do
        local invalid = payload
        it("rejects invalid values without committing or changing saved settings", function()
            local api = begin(DEFAULTS)
            local resp = api.appearance_save(invalid)
            assert.is_false(resp.success)
            assert.matches("Invalid appearance setting:", resp.error)
            assert.same({}, H.commits())
            assert.same(DEFAULTS, require("podkop-tweaker.appearance").read())
        end)
    end

    it("rejects non-table payloads", function()
        local api = begin({})
        assert.equal("Invalid appearance settings", api.appearance_save("bad").error)
        assert.same({}, H.commits())
    end)

    it("stores exact colors, canonicalizes HEX case, and allows low contrast choices", function()
        local api = begin({})
        local input = {
            color_success_light = "#FFFFFF", color_error_light = "#A01234", color_warning_light = "#AB5600",
            color_success_dark = "#01FE02", color_error_dark = "#FF7A7B", color_warning_dark = "#FEDCBA"
        }
        local result = api.appearance_save(input)
        assert.is_true(result.success)
        local uci = require("luci.model.uci").cursor()
        for key, value in pairs(input) do
            assert.equal(value:lower(), result.settings[key])
            assert.equal(value:lower(), uci:get("podkop-tweaker", "appearance", key))
        end
    end)

    it("falls back per color for malformed on-device metadata", function()
        begin({ color_success_dark = '\" onclick=\"bad', color_error_light = "url(x)", color_warning_dark = "#ABCDEF" })
        local settings = require("podkop-tweaker.appearance").read()
        assert.equal("#00ff00", settings.color_success_dark)
        assert.equal("#ff0000", settings.color_error_light)
        assert.equal("#abcdef", settings.color_warning_dark)
        assert.same({}, H.commits())
    end)

    for _, invalid_color in ipairs({ "#abc", "#aabbccdd", "#12zz34", "#112233;", "rgb(1,2,3)", '"/><script>', "#00ff00\n", "#00ff00 ", 123456, true, {} }) do
        local value = invalid_color
        it("rejects malformed color syntax before any settings writes", function()
            local api = begin({})
            assert.same({ success = false, error = "Invalid appearance setting: color_success_dark" }, api.appearance_save({ color_success_dark = value }))
            assert.same({}, H.commits())
            assert.same(DEFAULTS, require("podkop-tweaker.appearance").read())
        end)
    end

    it("appearance reset preserves all custom colors", function()
        local custom = { color_success_light = "#006611", color_error_light = "#cc0022", color_warning_light = "#bb3300",
            color_success_dark = "#11ff44", color_error_dark = "#ff4455", color_warning_dark = "#ff9922" }
        local saved = with_colors({ profile = "contrast", mono_font_size = "18", mono_font_weight = "500", mono_line_height = "1.8" })
        for key, value in pairs(custom) do saved[key] = value end
        local api = begin(saved)
        local result = api.appearance_reset()
        assert.is_true(result.success)
        assert.equal("soft", result.settings.profile)
        assert.equal("13", result.settings.mono_font_size)
        for key, value in pairs(custom) do assert.equal(value, result.settings[key]) end
    end)

    it("color reset preserves profile, font settings, visibility and unknown options", function()
        local api = begin({ profile = "contrast", mono_font_size = "18", mono_font_weight = "500", mono_line_height = "1.8", color_success_dark = "#123456" })
        local uci = require("luci.model.uci").cursor()
        uci:set("podkop-tweaker", "appearance", "future", "keep")
        local result = api.appearance_colors_reset()
        assert.same(with_colors({ profile = "contrast", mono_font_size = "18", mono_font_weight = "500", mono_line_height = "1.8" }), result.settings)
        assert.is_true(result.success)
        assert.equal("1", uci:get("podkop-tweaker", "settings", "show_argon_tab"))
        assert.equal("keep", uci:get("podkop-tweaker", "appearance", "future"))
        assert.same({ "podkop-tweaker" }, H.commits())
    end)

    it("each reset writes only its own fields, even with malformed legacy values elsewhere", function()
        local api = begin({ mono_font_size = "99", color_error_light = "invalid legacy value" })
        local uci = require("luci.model.uci").cursor()
        api.appearance_colors_reset()
        assert.equal("99", uci:get("podkop-tweaker", "appearance", "mono_font_size"))
        uci:set("podkop-tweaker", "appearance", "color_error_light", "invalid legacy value")
        api.appearance_reset()
        assert.equal("invalid legacy value", uci:get("podkop-tweaker", "appearance", "color_error_light"))
        assert.equal("#ff0000", require("podkop-tweaker.appearance").read().color_error_light)
    end)

    it("reset restores only app appearance defaults", function()
        local api = begin({ profile = "contrast", mono_font_size = "18" })
        local uci = require("luci.model.uci").cursor()
        uci:set("argon", "typography", "font_size", "19")
        assert.same({ success = true, settings = DEFAULTS }, api.appearance_reset())
        assert.equal("19", uci:get("argon", "typography", "font_size"))
        assert.equal("1", uci:get("podkop-tweaker", "settings", "show_argon_tab"))
    end)

    it("reports UCI commit failures for both save and reset", function()
        local api = begin({})
        require("luci.model.uci").cursor().commit = function() return false end
        assert.same({ success = false, error = "Cannot commit appearance settings" }, api.appearance_save(DEFAULTS))
        assert.same({ success = false, error = "Cannot commit appearance settings" }, api.appearance_reset())
        assert.same({ success = false, error = "Cannot commit appearance settings" }, api.appearance_colors_reset())
    end)

    it("hidden tab blocks all four APIs but keeps saved appearance active", function()
        local api = begin({ profile = "contrast", mono_font_size = "18" }, false)
        local disabled = { error = "Argon tab is disabled" }
        assert.same(disabled, api.appearance())
        assert.same(disabled, api.appearance_save({ profile = "soft" }))
        assert.same(disabled, api.appearance_reset())
        assert.same(disabled, api.appearance_colors_reset())
        assert.equal("contrast", require("podkop-tweaker.appearance").read().profile)
        assert.same({}, H.commits())
    end)
end)

describe("app configuration across Local / Git self-update", function()
    for _, relaxed in ipairs({ false, true }) do
        local mode = relaxed
        it("preserves existing appearance, visibility and unknown future options", function()
            H.begin({ sys = { { match = "find '", out = "/tmp/update/etc/config/podkop-tweaker\n/tmp/update/www/luci-static/resources/podkop-tweaker/common.css" } } })
            local config = "config settings 'settings'\n option show_argon_tab '1'\n option future 'keep'\nconfig appearance 'appearance'\n option profile 'contrast'\n option mono_font_size '18'\n option color_success_dark '#00ee11'\n option color_error_light '#ff0011'\n"
            H.vfs_write("/etc/config/podkop-tweaker", config)
            H.vfs_write("/tmp/update/etc/config/podkop-tweaker", "archive defaults")
            H.vfs_write("/tmp/update/www/luci-static/resources/podkop-tweaker/common.css", "new CSS")
            local copied = require("pt-subs-lib").apply_files_from_dir("/tmp/update", mode)
            assert.equal(1, copied)
            assert.equal(config, H.vfs_read("/etc/config/podkop-tweaker"))
            assert.equal("new CSS", H.vfs_read("/www/luci-static/resources/podkop-tweaker/common.css"))
        end)
    end

    it("installs defaults when there is no existing app config", function()
        H.begin({ sys = { { match = "find '", out = "/tmp/update/etc/config/podkop-tweaker" } } })
        H.vfs_write("/tmp/update/etc/config/podkop-tweaker", "first install defaults")
        assert.equal(1, require("pt-subs-lib").apply_files_from_dir("/tmp/update", false))
        assert.equal("first install defaults", H.vfs_read("/etc/config/podkop-tweaker"))
    end)
end)

describe("status colors in the Tweaker bundle item", function()
    it("round-trips the full configuration, including all six colors, while Argon is hidden", function()
        H.begin({ fv = { items = "tweaker" } })
        local config = "config settings 'settings'\n option show_argon_tab '0'\nconfig appearance 'appearance'\n option profile 'contrast'\n"
        for key, value in pairs(COLORS) do config = config .. " option " .. key .. " '" .. value .. "'\n" end
        config = config .. " option future 'keep'\n"
        H.vfs_write("/etc/config/podkop-tweaker", config)
        local bundle = require("podkop-tweaker.api_bundle")
        bundle.export()
        local exported = H.http().content()
        assert.equal(config, H.json.parse(exported).items.tweaker.content)
        H.vfs_write("/etc/config/podkop-tweaker", "config settings 'settings'\n option show_argon_tab '1'\n")
        local result = bundle.import(exported, nil, "tweaker")
        assert.is_true(result.success)
        assert.is_true(result.results.tweaker.ok)
        assert.equal(config, H.vfs_read("/etc/config/podkop-tweaker"))
        assert.is_false(result.restarting)
    end)
end)
