-- appearance_spec | v2.0.0 | 08.10.2026 | Color validation, independent resets and persistence
package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path
local H = require("pt_harness")
local CONFIG = "podkop-tweaker"
local CONFIG_PATH = "/etc/config/" .. CONFIG
local LOCK = "/var/lock/podkop-tweaker-tweaker.lock"
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

local function fixture_uci()
    local lines = {}
    local function quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end
    for _, section in ipairs(H.state().uci[CONFIG] or {}) do
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

local function begin(settings, enabled, opts)
    opts = opts or {}
    opts.strict = true
    opts.uci = opts.uci or {
        ["podkop-tweaker"] = {
            H.sec("settings", "settings", { show_argon_tab = enabled == false and "0" or "1" }),
            H.sec("appearance", "appearance", settings)
        }
    }
    H.begin(opts)
    H.vfs_write(CONFIG_PATH, fixture_uci())
    local uci = require("luci.model.uci").cursor()
    -- A native package get_all returns a section map, not individual option
    -- defaults. Keep the fixture explicit if the shared fake is still joining.
    if type(uci.get_all) ~= "function" then
        function uci:get_all(config, name)
            local failure = H.state().uci_failures[config]
            if failure and failure.get_all then return nil, "Injected UCI get_all failure" end
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
        if ok and config == CONFIG then H.vfs_write(CONFIG_PATH, fixture_uci()) end
        return ok, err
    end
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
        local uci = require("luci.model.uci").cursor()
        uci:set("argon", "typography", "typography")
        uci:set("argon", "typography", "font_size", "20")
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
        uci:set("argon", "typography", "typography")
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
        uci:set("argon", "typography", "typography")
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

describe("checked appearance reads", function()
    it("returns typed current values and an explicit source without creating defaults", function()
        local api = begin({ profile = "contrast", mono_font_size = "17", color_success_light = "#ABCDEF" })
        local before = H.vfs_read(CONFIG_PATH)
        local appearance = require("podkop-tweaker.appearance")
        local settings, err, source = appearance.read_checked()
        assert.is_nil(err)
        assert.equal("contrast", settings.profile)
        assert.equal("17", settings.mono_font_size)
        assert.equal("#abcdef", settings.color_success_light)
        assert.equal("#ff0000", settings.color_error_light)
        assert.same({ settings_source = "uci", config_missing = false }, source)
        assert.same(settings, api.appearance().settings)
        assert.equal(before, H.vfs_read(CONFIG_PATH))
        assert.same({}, H.commits())
    end)

    it("allows positively absent first-run configuration or an absent appearance section", function()
        local api = begin({})
        local uci = require("luci.model.uci").cursor()
        assert.is_true(uci:delete(CONFIG, "appearance"))
        H.vfs_write(CONFIG_PATH, fixture_uci())
        local response = api.appearance()
        assert.same(DEFAULTS, response.settings)
        assert.equal("defaults", response.settings_source)
        assert.is_false(response.config_missing)
        os.remove(CONFIG_PATH)
        local settings, err, source = require("podkop-tweaker.appearance").read_checked()
        assert.is_nil(err)
        assert.same(DEFAULTS, settings)
        assert.same({ settings_source = "defaults", config_missing = true }, source)
        assert.is_false(H.vfs_exists(CONFIG_PATH))
        assert.same({}, H.commits())
    end)

    for _, operation in ipairs({ "open", "read", "close" }) do
        local fail = operation
        it("stops all dependent APIs on a configuration " .. fail .. " failure", function()
            local api = begin({ profile = "contrast", future = "keep" }, true,
                { failures = { [CONFIG_PATH] = { [fail] = true } } })
            local before = H.vfs_read(CONFIG_PATH)
            local values, err = require("podkop-tweaker.appearance").read_checked()
            assert.is_nil(values)
            assert.truthy(err)
            local read = api.appearance()
            assert.truthy(read.error)
            assert.is_nil(read.settings)
            for _, action in ipairs({ "appearance_save", "appearance_reset", "appearance_colors_reset" }) do
                local response = api[action]({ mono_font_size = "14" })
                assert.is_false(response.success)
                assert.truthy(response.error)
                assert.is_nil(response.settings)
                assert.is_nil(response.uci_saved)
                assert.is_nil(response.partial)
            end
            assert.equal(before, H.vfs_read(CONFIG_PATH))
            assert.equal("contrast", require("luci.model.uci").cursor():get(CONFIG, "appearance", "profile"))
            assert.same({}, H.commits())
            assert.is_false(H.vfs_exists(LOCK))
        end)
    end

    for _, content in ipairs({ "", " \r\n\t", string.rep("x", 1048577) }) do
        local raw = content
        it("does not turn an empty or oversized existing package into writable defaults", function()
            local api = begin({ profile = "contrast" })
            H.vfs_write(CONFIG_PATH, raw)
            local values, err = require("podkop-tweaker.appearance").read_checked()
            assert.is_nil(values)
            assert.truthy(err)
            assert.is_nil(api.appearance().settings)
            for _, action in ipairs({ "appearance_save", "appearance_reset", "appearance_colors_reset" }) do
                assert.is_false(api[action]({ mono_font_size = "14" }).success)
            end
            assert.equal(raw, H.vfs_read(CONFIG_PATH))
            assert.same({}, H.commits())
        end)
    end

    for _, scenario in ipairs({
        { name = "nil RPC failure", get_all = function() return nil, "RPC unavailable" end },
        { name = "false RPC failure", get_all = function() return false, "RPC unavailable" end },
        { name = "RPC exception", get_all = function() error("RPC unavailable") end },
        { name = "error-shaped package", get_all = function() return { error = "RPC unavailable" } end },
        { name = "invalid section container", get_all = function() return { appearance = false } end },
        { name = "mismatched section name", get_all = function()
            return { appearance = { [".name"] = "another", [".type"] = "appearance" } }
        end },
        { name = "conflicting section type", get_all = function()
            return { appearance = { [".name"] = "appearance", [".type"] = "unknown_plugin", future = "keep" } }
        end }
    }) do
        local invalid = scenario
        it("rejects " .. invalid.name .. " before read-modify-write", function()
            local api = begin({ profile = "contrast", future = "keep" })
            local before = H.vfs_read(CONFIG_PATH)
            local uci = require("luci.model.uci").cursor()
            uci.get_all = invalid.get_all
            local values, err = require("podkop-tweaker.appearance").read_checked()
            assert.is_nil(values)
            assert.truthy(err)
            assert.is_nil(api.appearance().settings)
            for _, action in ipairs({ "appearance_save", "appearance_reset", "appearance_colors_reset" }) do
                local response = api[action]({ mono_font_size = "14" })
                assert.is_false(response.success)
                assert.truthy(response.error)
                assert.is_nil(response.settings)
                assert.is_nil(response.uci_saved)
            end
            assert.equal("contrast", require("podkop-tweaker.appearance").read().profile)
            assert.equal("keep", uci:get(CONFIG, "appearance", "future"))
            assert.equal(before, H.vfs_read(CONFIG_PATH))
            assert.same({}, H.commits())
            assert.is_false(H.vfs_exists(LOCK))
        end)
    end

    it("keeps render-time normalization separate from strict writable-form reads", function()
        local api = begin({ profile = "contrast", mono_font_size = "99", color_success_dark = "invalid legacy value" })
        local appearance = require("podkop-tweaker.appearance")
        assert.same(with_colors({ profile = "contrast", mono_font_size = "13", mono_font_weight = "400", mono_line_height = "1.6" }),
            appearance.read())
        local values, err = appearance.read_checked()
        assert.is_nil(values)
        assert.equal("Invalid appearance setting: mono_font_size", err)
        assert.is_nil(api.appearance().settings)
        assert.is_false(api.appearance_save({ mono_font_weight = "500" }).success)
        assert.same({}, H.commits())
        require("luci.model.uci").cursor().get = function() error("Render-time RPC failure") end
        assert.same(DEFAULTS, appearance.read())
    end)

    for _, malformed in ipairs({ { profile = { "contrast" } }, { mono_font_size = false },
        { color_success_dark = { "#00ff00" } } }) do
        local fields = malformed
        it("rejects non-scalar native setting values instead of enabling a default-filled form", function()
            local api = begin(fields)
            local settings, err = require("podkop-tweaker.appearance").read_checked()
            assert.is_nil(settings)
            assert.matches("Invalid appearance setting:", err)
            assert.is_nil(api.appearance().settings)
            assert.is_false(api.appearance_save({ mono_font_weight = "500" }).success)
            assert.same({}, H.commits())
            assert.is_table(require("podkop-tweaker.appearance").read())
        end)
    end
end)

describe("checked appearance mutation outcomes", function()
    for _, action in ipairs({ "appearance_save", "appearance_reset", "appearance_colors_reset" }) do
        local endpoint = action
        it(endpoint .. " updates an existing section without replacing unknown fields or other sections", function()
            local api = begin(with_colors({ profile = "contrast", mono_font_size = "17", mono_font_weight = "500", mono_line_height = "1.8" }))
            local uci = require("luci.model.uci").cursor()
            uci:set(CONFIG, "appearance", "future", { "first", "second" })
            uci:set(CONFIG, "settings", "future", "keep settings")
            uci:set(CONFIG, "plugin", "unknown_plugin")
            uci:set(CONFIG, "plugin", "opaque", "keep plugin")
            H.vfs_write(CONFIG_PATH, fixture_uci())
            local set = uci.set
            function uci:set(config, section, option, value)
                if config == CONFIG and section == "appearance" and value == nil then
                    error("An existing appearance section must not be re-created")
                end
                return set(self, config, section, option, value)
            end
            local response = api[endpoint]({ mono_font_size = "14" })
            assert.is_true(response.success)
            assert.same({ "first", "second" }, uci:get(CONFIG, "appearance", "future"))
            assert.equal("keep settings", uci:get(CONFIG, "settings", "future"))
            assert.equal("keep plugin", uci:get(CONFIG, "plugin", "opaque"))
            assert.equal("1", uci:get(CONFIG, "settings", "show_argon_tab"))
            local acquisitions = 0
            for _, entry in ipairs(H.state().io_log) do
                if entry.operation == "mkdir" and entry.path == LOCK then acquisitions = acquisitions + 1 end
            end
            assert.equal(1, acquisitions, "read, commit and checked readback share one reentrant lock")
            assert.is_false(H.vfs_exists(LOCK))
        end)

        it(endpoint .. " reports confirmed UCI publication when its checked readback fails", function()
            local api = begin(with_colors({ profile = "contrast", mono_font_size = "17", mono_font_weight = "500", mono_line_height = "1.8" }))
            local uci = require("luci.model.uci").cursor()
            local commit = uci.commit
            function uci:commit(config)
                local ok, err = commit(self, config)
                if ok and config == CONFIG then
                    self.get_all = function() return nil, "Readback unavailable" end
                end
                return ok, err
            end
            local response = api[endpoint]({ mono_font_size = "14" })
            assert.is_false(response.success)
            assert.equal("Readback unavailable", response.error)
            assert.is_true(response.uci_saved)
            assert.is_true(response.partial)
            assert.is_true(response.applied)
            assert.is_nil(response.settings)
            assert.same({ CONFIG }, H.commits())
            assert.is_false(H.vfs_exists(LOCK))
        end)

        it(endpoint .. " reports lock-release failure after a confirmed commit without returning defaults", function()
            local api = begin(with_colors({ profile = "contrast", mono_font_size = "17", mono_font_weight = "500", mono_line_height = "1.8" }), true,
                { failures = { [LOCK] = { rmdir = true } } })
            local response = api[endpoint]({ mono_font_size = "14" })
            assert.is_false(response.success)
            assert.truthy(response.error)
            assert.is_true(response.uci_saved)
            assert.is_true(response.partial)
            assert.is_true(response.applied)
            assert.equal(response.error, response.lock_error)
            assert.is_true(response.unknown)
            assert.is_nil(response.settings)
            assert.same({ CONFIG }, H.commits())
            assert.is_true(H.vfs_exists(LOCK), "failed owned-lock cleanup is retained")
        end)
    end

    it("creates only a positively missing appearance section", function()
        local api = begin({})
        local uci = require("luci.model.uci").cursor()
        assert.is_true(uci:delete(CONFIG, "appearance"))
        uci:set(CONFIG, "settings", "future", "keep")
        H.vfs_write(CONFIG_PATH, fixture_uci())
        local response = api.appearance_save({ mono_font_size = "14" })
        assert.is_true(response.success)
        assert.equal("appearance", uci:get(CONFIG, "appearance"))
        assert.equal("14", response.settings.mono_font_size)
        assert.equal("soft", response.settings.profile)
        assert.equal("keep", uci:get(CONFIG, "settings", "future"))
    end)

    it("preserves unrelated malformed legacy fields and reports the partial reset instead of rendering defaults", function()
        local api = begin({ mono_font_size = "99", color_error_light = "bad legacy color", future = "keep" })
        local colors = api.appearance_colors_reset()
        assert.is_false(colors.success)
        assert.is_true(colors.uci_saved)
        assert.is_true(colors.partial)
        assert.is_nil(colors.settings)
        local uci = require("luci.model.uci").cursor()
        assert.equal("99", uci:get(CONFIG, "appearance", "mono_font_size"))
        assert.equal("#ff0000", uci:get(CONFIG, "appearance", "color_error_light"))
        uci:set(CONFIG, "appearance", "color_error_light", "bad legacy color")
        local fonts = api.appearance_reset()
        assert.is_false(fonts.success)
        assert.is_true(fonts.uci_saved)
        assert.is_true(fonts.partial)
        assert.is_nil(fonts.settings)
        assert.equal("13", uci:get(CONFIG, "appearance", "mono_font_size"))
        assert.equal("bad legacy color", uci:get(CONFIG, "appearance", "color_error_light"))
        assert.equal("keep", uci:get(CONFIG, "appearance", "future"))
    end)

    it("does not treat release uncertainty as a saved UI configuration when no commit happened", function()
        local api = begin(DEFAULTS, true, { failures = { [LOCK] = { rmdir = true } } })
        local before = H.vfs_read(CONFIG_PATH)
        local response = api.appearance_save({ mono_font_size = "99" })
        assert.is_false(response.success)
        assert.equal("Invalid appearance setting: mono_font_size", response.error)
        assert.truthy(response.lock_error)
        assert.are_not.equal(response.error, response.lock_error)
        assert.is_true(response.unknown)
        assert.is_nil(response.uci_saved)
        assert.is_nil(response.partial)
        assert.is_nil(response.applied)
        assert.is_nil(response.settings)
        assert.equal(before, H.vfs_read(CONFIG_PATH))
        assert.same({}, H.commits())
    end)

    it("does not expose a writable read after lock-release failure", function()
        local api = begin({ profile = "contrast" }, true, { failures = { [LOCK] = { rmdir = true } } })
        local response = api.appearance()
        assert.is_false(response.success)
        assert.truthy(response.error)
        assert.equal(response.error, response.lock_error)
        assert.is_true(response.unknown)
        assert.is_nil(response.settings)
        assert.is_nil(response.settings_source)
        assert.is_nil(response.config_missing)
        assert.is_nil(response.uci_saved)
        assert.is_nil(response.partial)
        assert.is_nil(response.applied)
        assert.same({}, H.commits())
    end)

    for _, first_run in ipairs({ false, true }) do
        local missing = first_run
        it("does not return checked current values or first-run defaults after release failure", function()
            begin({ profile = "contrast" }, true, { failures = { [LOCK] = { rmdir = true } } })
            if missing then os.remove(CONFIG_PATH) end
            local settings, err, info = require("podkop-tweaker.appearance").read_checked()
            assert.is_nil(settings)
            assert.truthy(err)
            assert.is_true(info.unknown)
            assert.equal(err, info.lock_error)
            assert.is_nil(info.settings_source)
            assert.is_nil(info.config_missing)
            assert.is_nil(info.uci_saved)
            assert.is_nil(info.applied)
            assert.is_nil(info.partial)
            assert.same({}, H.commits())
        end)
    end

    it("preserves the full primary checked-read error beside release diagnostics", function()
        begin({ profile = "contrast" }, true, { failures = { [LOCK] = { rmdir = true } } })
        local primary = "Primary UCI read failure\n" .. string.rep("complete read diagnostic <plain text>\n", 1000)
        require("luci.model.uci").cursor().get_all = function() return nil, primary end
        local settings, err, info = require("podkop-tweaker.appearance").read_checked()
        assert.is_nil(settings)
        assert.equal(primary, err)
        assert.is_true(info.unknown)
        assert.truthy(info.lock_error)
        assert.are_not.equal(primary, info.lock_error)
        assert.is_nil(info.settings_source)
        assert.is_nil(info.applied)
        assert.same({}, H.commits())
    end)

    it("propagates a primary read error and release uncertainty through the appearance GET API", function()
        local api = begin({ profile = "contrast" }, true, { failures = { [LOCK] = { rmdir = true } } })
        local primary = "Primary native read failure\n" .. string.rep("complete RPC diagnostic\n", 1000)
        require("luci.model.uci").cursor().get_all = function() return false, primary end
        local response = api.appearance()
        assert.is_false(response.success)
        assert.equal(primary, response.error)
        assert.is_true(response.unknown)
        assert.truthy(response.lock_error)
        assert.are_not.equal(primary, response.lock_error)
        assert.is_nil(response.settings)
        assert.is_nil(response.uci_saved)
        assert.is_nil(response.applied)
        assert.is_nil(response.partial)
        assert.same({}, H.commits())
    end)

    for _, action in ipairs({ "appearance_save", "appearance_reset", "appearance_colors_reset" }) do
        local endpoint = action
        it(endpoint .. " keeps primary commit failure and complete diagnostics when release fails too", function()
            local api = begin(DEFAULTS, true, { failures = { [LOCK] = { rmdir = true } } })
            local before = H.vfs_read(CONFIG_PATH)
            local details = string.rep("complete native commit diagnostic <plain text>\n", 1000)
            require("luci.model.uci").cursor().commit = function() return false, details end
            local response = api[endpoint]({ mono_font_size = "14" })
            assert.is_false(response.success)
            assert.equal("Cannot commit appearance settings", response.error)
            assert.equal(details, response.details)
            assert.is_true(response.unknown)
            assert.truthy(response.lock_error)
            assert.are_not.equal(response.error, response.lock_error)
            assert.is_nil(response.uci_saved)
            assert.is_nil(response.partial)
            assert.is_nil(response.applied)
            assert.is_nil(response.settings)
            assert.equal(before, H.vfs_read(CONFIG_PATH))
            assert.same({}, H.commits())
        end)
    end

    it("preserves readback failure after a confirmed commit and independently reports release uncertainty", function()
        local api = begin(DEFAULTS, true, { failures = { [LOCK] = { rmdir = true } } })
        local primary = "Primary readback failure\n" .. string.rep("full readback diagnostic\n", 1000)
        local uci = require("luci.model.uci").cursor()
        local commit = uci.commit
        function uci:commit(config)
            local ok, err = commit(self, config)
            if ok and config == CONFIG then self.get_all = function() return nil, primary end end
            return ok, err
        end
        local response = api.appearance_save({ mono_font_size = "14" })
        assert.is_false(response.success)
        assert.equal(primary, response.error)
        assert.is_true(response.unknown)
        assert.truthy(response.lock_error)
        assert.are_not.equal(primary, response.lock_error)
        assert.is_true(response.uci_saved)
        assert.is_true(response.partial)
        assert.is_true(response.applied)
        assert.is_nil(response.settings)
        assert.equal("14", uci:get(CONFIG, "appearance", "mono_font_size"))
        assert.same({ CONFIG }, H.commits())
    end)

    it("retains a confirmed save outcome when the readback file close fails", function()
        local api = begin(with_colors({ profile = "contrast", mono_font_size = "17", mono_font_weight = "500", mono_line_height = "1.8" }))
        local uci = require("luci.model.uci").cursor()
        local commit = uci.commit
        function uci:commit(config)
            local ok, err = commit(self, config)
            if ok and config == CONFIG then H.state().failures[CONFIG_PATH] = { close = true } end
            return ok, err
        end
        local response = api.appearance_save({ mono_font_size = "14" })
        assert.is_false(response.success)
        assert.truthy(response.error)
        assert.is_true(response.uci_saved)
        assert.is_true(response.partial)
        assert.is_true(response.applied)
        assert.is_nil(response.settings)
        assert.equal("14", uci:get(CONFIG, "appearance", "mono_font_size"))
        assert.equal("contrast", uci:get(CONFIG, "appearance", "profile"))
        assert.same({ CONFIG }, H.commits())
        assert.is_false(H.vfs_exists(LOCK))
    end)

    for _, action in ipairs({ "appearance_save", "appearance_reset", "appearance_colors_reset" }) do
        local endpoint = action
        for _, missing in ipairs({ "configuration", "section" }) do
            local removed = missing
            it(endpoint .. " rejects first-run defaults when the committed " .. removed .. " disappears", function()
                local api = begin(with_colors({ profile = "contrast", mono_font_size = "17", mono_font_weight = "500", mono_line_height = "1.8" }))
                local uci = require("luci.model.uci").cursor()
                local commit = uci.commit
                function uci:commit(config)
                    local ok, err = commit(self, config)
                    if ok and config == CONFIG then
                        -- External writers are not serialized by the app lock.
                        if removed == "configuration" then os.remove(CONFIG_PATH)
                        else
                            assert.is_true(self:delete(CONFIG, "appearance"))
                            H.vfs_write(CONFIG_PATH, fixture_uci())
                        end
                    end
                    return ok, err
                end
                local response = api[endpoint]({ mono_font_size = "14" })
                assert.is_false(response.success)
                assert.equal(removed == "configuration" and "Saved Tweaker configuration is missing" or
                    "Saved appearance section is missing", response.error)
                assert.is_true(response.uci_saved)
                assert.is_true(response.partial)
                assert.is_true(response.applied)
                assert.is_nil(response.settings)
                assert.is_nil(response.unknown, "known absence is not lock-release uncertainty")
                assert.same({ CONFIG }, H.commits())
                assert.is_false(H.vfs_exists(LOCK))
            end)
        end
    end
end)

describe("appearance and bundle resource coordination", function()
    it("locks before a partial-save read so a competing full Tweaker import cannot interleave", function()
        local api = begin(with_colors({ profile = "contrast", mono_font_size = "17", mono_font_weight = "500", mono_line_height = "1.8" }))
        local bundle = require("podkop-tweaker.bundle")
        local attempted, imported, import_err = false, nil, nil
        local actor = coroutine.create(function()
            imported, import_err = bundle.apply_item("tweaker", {
                content = "config settings 'settings'\n option show_argon_tab '1'\nconfig appearance 'appearance'\n option profile 'soft'\n"
            }, {})
        end)
        local uci = require("luci.model.uci").cursor()
        local get_all = uci.get_all
        function uci:get_all(config, name)
            if config == CONFIG then
                assert.is_true(H.vfs_exists(LOCK), "the current read belongs inside the mutation lock")
                if not attempted then
                    attempted = true
                    local resumed, err = coroutine.resume(actor)
                    assert.is_true(resumed, err)
                    assert.is_false(imported)
                    assert.truthy(import_err)
                end
            end
            return get_all(self, config, name)
        end
        local response = api.appearance_save({ mono_font_size = "14" })
        assert.is_true(response.success)
        assert.is_true(attempted)
        assert.equal("contrast", response.settings.profile)
        assert.equal("14", response.settings.mono_font_size)
        assert.equal("500", response.settings.mono_font_weight)
        assert.equal("#00be00", response.settings.color_success_light)
        assert.same({ CONFIG }, H.commits())
        assert.is_false(H.vfs_exists(CONFIG_PATH .. ".bundle-backup"))
        assert.is_false(H.vfs_exists(LOCK))
    end)

    it("refuses checked reads and every appearance setter while a full bundle import holds tweaker", function()
        local api = begin({ profile = "contrast" })
        local bundle = require("podkop-tweaker.bundle")
        local srv = require("podkop-tweaker.services")
        local publish = srv.publish_file
        local attempted = false
        srv.publish_file = function(stage, target)
            if target == CONFIG_PATH then
                assert.is_true(H.vfs_exists(LOCK))
                local actor = coroutine.create(function()
                    local response = api.appearance()
                    assert.truthy(response.error)
                    assert.is_nil(response.settings)
                    for _, action in ipairs({ "appearance_save", "appearance_reset", "appearance_colors_reset" }) do
                        local mutation = api[action]({ mono_font_size = "14" })
                        assert.is_false(mutation.success)
                        assert.truthy(mutation.error)
                        assert.is_nil(mutation.uci_saved)
                    end
                end)
                local resumed, err = coroutine.resume(actor)
                assert.is_true(resumed, err)
                attempted = true
            end
            return publish(stage, target)
        end
        local imported = "config settings 'settings'\n option show_argon_tab '1'\nconfig appearance 'appearance'\n option profile 'soft'\n"
        local ok, err = bundle.apply_item("tweaker", { content = imported }, {})
        assert.is_true(ok, err)
        assert.is_true(attempted)
        assert.equal(imported, H.vfs_read(CONFIG_PATH))
        assert.same({}, H.commits())
        assert.is_false(H.vfs_exists(LOCK))
    end)
end)

describe("app configuration across Local / Git self-update", function()
    local configs = {
        {
            path = "etc/config/podkop-tweaker",
            current = "config settings 'settings'\n option show_argon_tab '1'\n option future 'keep'\nconfig appearance 'appearance'\n option profile 'contrast'\n option mono_font_size '18'\n option color_success_dark '#00ee11'\n option color_error_light '#ff0011'\n",
            defaults = "config settings 'settings'\n option show_argon_tab '0'\n"
        },
        {
            path = "etc/config/podkop-fragment",
            current = table.concat({
                "# Administrator-owned Fragment configuration",
                "config fragment 'settings'",
                " option enabled '0'",
                " option fragment 'true'",
                " option record_fragment 'false'",
                " option fragment_fallback_delay '750ms'",
                " option singbox_config '/etc/sing-box/custom.json'",
                " option log_file '/tmp/custom-fragment.log'",
                " option log_max_lines '75'",
                " option future 'keep'",
                "config custom 'extra'",
                " list future_items 'first'",
                " list future_items 'second'", ""
            }, "\n"),
            defaults = "config fragment 'settings'\n option enabled '1'\n option record_fragment 'true'\n"
        }
    }
    local css = "www/luci-static/resources/podkop-tweaker/common.css"
    for _, relaxed in ipairs({ false, true }) do
        local mode = relaxed
        local label = mode and "Git relaxed" or "Local strict"
        for _, manifest in ipairs({ false, true }) do
            local use_paths = manifest
            it(label .. " preserves appearance and disabled/custom Fragment UCI with " .. (use_paths and "manifest paths" or "file discovery"), function()
                local paths = { configs[1].path, configs[2].path, css }
                H.begin({ sys = { { match = "find '", out = "/tmp/update/" .. table.concat(paths, "\n/tmp/update/") } } })
                for _, config in ipairs(configs) do
                    H.vfs_write("/" .. config.path, config.current)
                    H.vfs_write("/tmp/update/" .. config.path, config.defaults)
                end
                H.vfs_write("/tmp/update/" .. css, "new CSS")
                local copied, err = require("pt-subs-lib").apply_files_from_dir("/tmp/update", mode, use_paths and paths or nil)
                assert.is_nil(err)
                assert.equal(1, copied)
                for _, config in ipairs(configs) do
                    assert.equal(config.current, H.vfs_read("/" .. config.path))
                    assert.falsy(H.vfs_exists("/" .. config.path .. ".tmp-update"))
                end
                assert.equal("new CSS", H.vfs_read("/" .. css))
            end)
        end

        it(label .. " installs both archived defaults when app-owned configs are absent", function()
            H.begin()
            local paths = {}
            for _, config in ipairs(configs) do
                paths[#paths + 1] = config.path
                H.vfs_write("/tmp/update/" .. config.path, config.defaults)
            end
            local copied, err = require("pt-subs-lib").apply_files_from_dir("/tmp/update", mode, paths)
            assert.is_nil(err)
            assert.equal(2, copied)
            for _, config in ipairs(configs) do
                assert.equal(config.defaults, H.vfs_read("/" .. config.path))
            end
        end)

        for _, entry in ipairs(configs) do
            local config = entry
            for _, errno in ipairs({ 5, 13 }) do
                local code = errno
                it(label .. " rejects existing " .. config.path .. " open errno " .. code .. " without overwriting", function()
                    local dest = "/" .. config.path
                    H.begin({ failures = { [dest] = { open = true, errno = code } } })
                    H.vfs_write(dest, config.current)
                    H.vfs_write("/tmp/update/" .. config.path, config.defaults)
                    H.vfs_write("/tmp/update/" .. css, "new CSS")
                    local copied, err = require("pt-subs-lib").apply_files_from_dir("/tmp/update", mode, { config.path, css })
                    assert.equal(0, copied)
                    assert.equal("Cannot read existing app configuration: Injected open failure", err)
                    assert.equal(config.current, H.vfs_read(dest))
                    assert.falsy(H.vfs_exists(dest .. ".tmp-update"))
                    assert.falsy(H.vfs_exists("/" .. css))
                end)
            end
        end
    end
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
