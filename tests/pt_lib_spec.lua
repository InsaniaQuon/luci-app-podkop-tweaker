package.path = "./usr/lib/lua/?.lua;" .. package.path

local LIB = require("podkop-tweaker.lib")

describe("parse_version", function()
    it("parses full semver", function()
        assert.same({ 1, 2, 3 }, LIB.parse_version("1.2.3"))
    end)

    it("strips leading v", function()
        assert.same({ 4, 0, 0 }, LIB.parse_version("v4.0.0"))
    end)

    it("returns nil for two-component version", function()
        assert.is_nil(LIB.parse_version("1.2"))
    end)

    it("returns nil for garbage", function()
        assert.is_nil(LIB.parse_version("abc"))
    end)

    it("returns nil for nil input", function()
        assert.is_nil(LIB.parse_version(nil))
    end)
end)

describe("version_lt", function()
    it("detects older version", function()
        assert.is_true(LIB.version_lt("1.2.3", "1.2.4"))
        assert.is_true(LIB.version_lt("1.2.3", "2.0.0"))
        assert.is_true(LIB.version_lt("3.9.9", "3.10.0"))
    end)

    it("detects equal versions", function()
        assert.is_false(LIB.version_lt("1.2.3", "1.2.3"))
    end)

    it("detects newer version", function()
        assert.is_false(LIB.version_lt("2.0.0", "1.9.9"))
    end)

    it("handles v prefix on both sides", function()
        assert.is_true(LIB.version_lt("v1.0.0", "v1.0.1"))
    end)

    it("returns false when either version is invalid", function()
        assert.is_false(LIB.version_lt("bad", "1.0.0"))
        assert.is_false(LIB.version_lt("1.0.0", "bad"))
        assert.is_false(LIB.version_lt(nil, "1.0.0"))
    end)
end)

describe("sanitize_section_name", function()
    it("accepts alphanumeric, underscore, dash", function()
        assert.equal("cfg_1-A", LIB.sanitize_section_name("cfg_1-A"))
    end)

    it("rejects dots, slashes and spaces", function()
        assert.is_nil(LIB.sanitize_section_name("a.b"))
        assert.is_nil(LIB.sanitize_section_name("../../etc"))
        assert.is_nil(LIB.sanitize_section_name("a b"))
    end)

    it("rejects empty and nil", function()
        assert.is_nil(LIB.sanitize_section_name(""))
        assert.is_nil(LIB.sanitize_section_name(nil))
    end)
end)

describe("validate_uci_config", function()
    it("accepts a valid config", function()
        local ok = LIB.validate_uci_config("config section 'a'\n\toption key 'value'\n\tlist items 'x'\n")
        assert.is_true(ok)
    end)

    it("rejects empty content", function()
        local ok, err = LIB.validate_uci_config("")
        assert.is_false(ok)
        assert.equal("Configuration is empty", err)
    end)

    it("rejects nil content", function()
        local ok = LIB.validate_uci_config(nil)
        assert.is_false(ok)
    end)

    it("rejects oversized content", function()
        local big = string.rep("config a\n", 200000)
        local ok, err = LIB.validate_uci_config(big)
        assert.is_false(ok)
        assert.equal("Config too large (max 1MB)", err)
    end)

    it("rejects content without config declarations", function()
        local ok = LIB.validate_uci_config("just some text\n")
        assert.is_false(ok)
    end)

    it("rejects null bytes", function()
        local ok = LIB.validate_uci_config("config a\n\0")
        assert.is_false(ok)
    end)

    it("rejects unknown top-level tokens", function()
        local ok = LIB.validate_uci_config("config a\nbadtoken foo\n")
        assert.is_false(ok)
    end)

    it("allows comments", function()
        local ok = LIB.validate_uci_config("config a\n# comment line\n")
        assert.is_true(ok)
    end)

    it("rejects control characters", function()
        local ok = LIB.validate_uci_config("config a\n\toption k 'v'\1\n")
        assert.is_false(ok)
    end)

    it("rejects unmatched single quote", function()
        local ok = LIB.validate_uci_config("config a\n\toption k 'value\n")
        assert.is_false(ok)
    end)

    it("rejects unmatched double quote", function()
        local ok = LIB.validate_uci_config('config a\n\toption k "value\n')
        assert.is_false(ok)
    end)

    it("allows quoted hash inside option value", function()
        local ok = LIB.validate_uci_config("config a\n\toption k '# not comment'\n")
        assert.is_true(ok)
    end)
end)

describe("clamp_str", function()
    it("keeps value in range", function()
        assert.equal("16", LIB.clamp_str("16", 13, 20))
    end)

    it("empties out-of-range value", function()
        assert.equal("", LIB.clamp_str("25", 13, 20))
        assert.equal("", LIB.clamp_str("0.5", 1.0, 2.0))
    end)

    it("empties non-numeric value", function()
        assert.equal("", LIB.clamp_str("abc", 1, 2))
    end)

    it("empties nil and empty", function()
        assert.equal("", LIB.clamp_str(nil, 1, 2))
        assert.equal("", LIB.clamp_str("", 1, 2))
    end)
end)

describe("generate_argon_css", function()
    it("generates empty block for empty settings", function()
        local css = LIB.generate_argon_css({})
        assert.truthy(css:find("Podkop Tweaker Typography", 1, true))
        assert.truthy(css:find("End Podkop Tweaker Typography", 1, true))
        assert.falsy(css:find(":root", 1, true))
    end)

    it("emits root font-size and family", function()
        local css = LIB.generate_argon_css({ font_size = "16", font_family = "Arial" })
        assert.truthy(css:find("font-size: 16px;", 1, true))
        assert.truthy(css:find("--font-family-sans-serif: Arial, Helvetica, sans-serif;", 1, true))
    end)

    it("uses custom family when selected", function()
        local css = LIB.generate_argon_css({ font_family = "custom", font_family_custom = "'Roboto', sans-serif" })
        assert.truthy(css:find("--font-family-sans-serif: 'Roboto', sans-serif;", 1, true))
    end)

    it("omits family for unknown preset", function()
        local css = LIB.generate_argon_css({ font_family = "Nope" })
        assert.falsy(css:find("font-family", 1, true))
    end)

    it("emits body rules and menu rule", function()
        local css = LIB.generate_argon_css({
            font_weight = "500", line_height = "1.5", letter_spacing = "0.2",
            menu_font_size = "0.9", menu_padding = "10"
        })
        assert.truthy(css:find("font-weight: 500;", 1, true))
        assert.truthy(css:find("line-height: 1.5;", 1, true))
        assert.truthy(css:find("letter-spacing: 0.2px;", 1, true))
        assert.truthy(css:find(".main-left .nav li a { font-size: 0.9rem; padding-top: 10px; padding-bottom: 10px; }", 1, true))
    end)
end)

describe("ARGON_FONT_FAMILIES", function()
    it("contains known presets", function()
        assert.truthy(LIB.ARGON_FONT_FAMILIES["Google Sans"])
        assert.truthy(LIB.ARGON_FONT_FAMILIES["monospace"])
    end)
end)
