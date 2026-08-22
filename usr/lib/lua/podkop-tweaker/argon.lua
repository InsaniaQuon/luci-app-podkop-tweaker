-- Podkop Tweaker | Argon theme typography module (UCI + CSS injection)
-- Author: InsaniaQuon

local LIB = require("podkop-tweaker.lib")

local M = {}

local CASCADE_CSS = LIB.ARGON_CASCADE_CSS
local MARKER_START = LIB.ARGON_CSS_MARKER_START
local MARKER_END = LIB.ARGON_CSS_MARKER_END

function M.read_settings()
    local uci = require("luci.model.uci").cursor()
    return {
        font_size = uci:get("argon", "typography", "font_size") or "",
        font_family = uci:get("argon", "typography", "font_family") or "Google Sans",
        font_family_custom = uci:get("argon", "typography", "font_family_custom") or "",
        font_weight = uci:get("argon", "typography", "font_weight") or "400",
        line_height = uci:get("argon", "typography", "line_height") or "",
        letter_spacing = uci:get("argon", "typography", "letter_spacing") or "",
        menu_font_size = uci:get("argon", "typography", "menu_font_size") or "",
        menu_padding = uci:get("argon", "typography", "menu_padding") or ""
    }
end

function M.check_stale()
    local fd = io.open(CASCADE_CSS, "r")
    if not fd then return true end
    local content = fd:read("*a")
    fd:close()
    return not content:find("Podkop Tweaker Typography", 1, true)
end

function M.inject_css(css_block)
    local fd = io.open(CASCADE_CSS, "r")
    if not fd then return false end
    local content = fd:read("*a")
    fd:close()
    local start_pos = content:find(MARKER_START, 1, true)
    if start_pos then
        local end_pos = content:find(MARKER_END, start_pos, true)
        if end_pos then
            end_pos = end_pos + #MARKER_END
            while content:sub(end_pos, end_pos):match("[\r\n]") do
                end_pos = end_pos + 1
            end
            content = content:sub(1, start_pos - 1):gsub("[\r\n]+$", "") .. "\n" .. css_block .. "\n" .. content:sub(end_pos)
        end
    else
        content = content:gsub("[\r\n]+$", "") .. "\n" .. css_block .. "\n"
    end
    local wfd = io.open(CASCADE_CSS, "w")
    if not wfd then return false end
    wfd:write(content)
    wfd:close()
    return true
end

function M.remove_css()
    local fd = io.open(CASCADE_CSS, "r")
    if not fd then return end
    local content = fd:read("*a")
    fd:close()
    local start_pos = content:find(MARKER_START, 1, true)
    if not start_pos then return end
    local end_pos = content:find(MARKER_END, start_pos, true)
    if not end_pos then return end
    end_pos = end_pos + #MARKER_END
    while content:sub(end_pos, end_pos):match("[\r\n]") do
        end_pos = end_pos + 1
    end
    content = content:sub(1, start_pos - 1):gsub("[\r\n]+$", "") .. "\n"
    local wfd = io.open(CASCADE_CSS, "w")
    if wfd then
        wfd:write(content)
        wfd:close()
    end
end

function M.apply()
    local settings = M.read_settings()
    local css = LIB.generate_argon_css(settings)
    return M.inject_css(css)
end

function M.tab_disabled()
    local uci = require("luci.model.uci").cursor()
    return uci:get("podkop-tweaker", "settings", "show_argon_tab") ~= "1"
end

return M
