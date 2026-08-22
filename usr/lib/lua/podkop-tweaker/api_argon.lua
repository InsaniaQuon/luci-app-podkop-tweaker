-- Podkop Tweaker | Argon typography API handlers
-- Author: InsaniaQuon

local H = require("podkop-tweaker.http")
local AR = require("podkop-tweaker.argon")
local LIB = require("podkop-tweaker.lib")

local M = {}

function M.typography()
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()
    if AR.tab_disabled() then
        http.write_json({ error = "Argon tab is disabled" })
        return
    end
    local settings = AR.read_settings()
    local families = {}
    for k, _ in pairs(LIB.ARGON_FONT_FAMILIES) do
        table.insert(families, k)
    end
    table.sort(families)
    http.write_json({
        settings = settings,
        stale = AR.check_stale(),
        font_families = families
    })
end

function M.typography_save()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()
    if AR.tab_disabled() then
        http.write_json({ error = "Argon tab is disabled" })
        return
    end
    local uci = require("luci.model.uci").cursor()
    local font_size = http.formvalue("font_size") or ""
    if font_size ~= "" then
        local n = tonumber(font_size)
        if not n or n < 13 or n > 20 then font_size = "" end
    end
    local font_family = http.formvalue("font_family") or "Google Sans"
    local font_family_custom = http.formvalue("font_family_custom") or ""
    font_family_custom = font_family_custom:gsub("[^%w%s,'%-]", "")
    local font_weight = http.formvalue("font_weight") or "400"
    if not font_weight:match("^[0-9]+$") then font_weight = "400" end
    local line_height = http.formvalue("line_height") or ""
    if line_height ~= "" then
        local n = tonumber(line_height)
        if not n or n < 1.0 or n > 2.0 then line_height = "" end
    end
    local letter_spacing = http.formvalue("letter_spacing") or ""
    if letter_spacing ~= "" then
        local n = tonumber(letter_spacing)
        if not n or n < -0.5 or n > 2.0 then letter_spacing = "" end
    end
    local menu_font_size = http.formvalue("menu_font_size") or ""
    if menu_font_size ~= "" then
        local n = tonumber(menu_font_size)
        if not n or n < 0.7 or n > 1.2 then menu_font_size = "" end
    end
    local menu_padding = http.formvalue("menu_padding") or ""
    if menu_padding ~= "" then
        local n = tonumber(menu_padding)
        if not n or n < 5 or n > 20 then menu_padding = "" end
    end
    uci:set("argon", "typography", "typography")
    uci:set("argon", "typography", "font_size", font_size)
    uci:set("argon", "typography", "font_family", font_family)
    uci:set("argon", "typography", "font_family_custom", font_family_custom)
    uci:set("argon", "typography", "font_weight", font_weight)
    uci:set("argon", "typography", "line_height", line_height)
    uci:set("argon", "typography", "letter_spacing", letter_spacing)
    uci:set("argon", "typography", "menu_font_size", menu_font_size)
    uci:set("argon", "typography", "menu_padding", menu_padding)
    uci:commit("argon")
    local ok = AR.apply()
    http.write_json({ success = ok, stale = AR.check_stale() })
end

function M.typography_reset()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()
    if AR.tab_disabled() then
        http.write_json({ error = "Argon tab is disabled" })
        return
    end
    local uci = require("luci.model.uci").cursor()
    uci:set("argon", "typography", "typography")
    uci:set("argon", "typography", "font_size", "")
    uci:set("argon", "typography", "font_family", "Google Sans")
    uci:set("argon", "typography", "font_family_custom", "")
    uci:set("argon", "typography", "font_weight", "400")
    uci:set("argon", "typography", "line_height", "")
    uci:set("argon", "typography", "letter_spacing", "")
    uci:set("argon", "typography", "menu_font_size", "")
    uci:set("argon", "typography", "menu_padding", "")
    uci:commit("argon")
    AR.remove_css()
    http.write_json({ success = true, stale = true })
end

function M.reinject()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()
    if AR.tab_disabled() then
        http.write_json({ error = "Argon tab is disabled" })
        return
    end
    local ok = AR.apply()
    http.write_json({ success = ok, stale = AR.check_stale() })
end

return M
