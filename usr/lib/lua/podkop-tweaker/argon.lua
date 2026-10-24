-- Podkop Tweaker | Argon theme typography module (UCI + CSS injection)
-- Author: InsaniaQuon

local LIB = require("podkop-tweaker.lib")
local SRV = require("podkop-tweaker.services")

local M = {}

local CASCADE_CSS = LIB.ARGON_CASCADE_CSS
local MARKER_START = LIB.ARGON_CSS_MARKER_START
local MARKER_END = LIB.ARGON_CSS_MARKER_END
local CONFIG = "/etc/config/argon"
local CSS_MAX_SIZE = 4194304
local DEFAULTS = {
    font_size = "", font_family = "Google Sans", font_family_custom = "", font_weight = "400",
    line_height = "", letter_spacing = "", menu_font_size = "", menu_padding = ""
}
local FIELDS = { "font_size", "font_family", "font_family_custom", "font_weight",
    "line_height", "letter_spacing", "menu_font_size", "menu_padding" }
local RANGES = { font_size = { 13, 20 }, font_weight = { 300, 700 }, line_height = { 1, 2 },
    letter_spacing = { -0.5, 2 }, menu_font_size = { 0.7, 1.2 }, menu_padding = { 5, 20 } }

-- Also used around the API's complete UCI + CSS operation. The services lock is
-- reentrant only for the current actor, so bundle/theme helper calls share it.
function M.with_lock(fn)
    return SRV.with_lock("argon-css", fn)
end

local function locked_result(fn)
    local primary_err, operation_info
    local result, err, uncertain, info = M.with_lock(function()
        local value, value_err, value_info, diagnostics = fn()
        primary_err, operation_info = value_err, diagnostics
        return value, value_err, value_info, diagnostics
    end)
    if result == nil and uncertain == true then
        info = operation_info or {}
        info.unknown, info.lock_error = true, err
        return nil, primary_err or err, true, info
    end
    return result, err, uncertain, info
end

local function locked_write(fn)
    local ok, err, uncertain, info = locked_result(fn)
    -- The third return describes release uncertainty, never disk application.
    return ok == true, err, uncertain, info
end

local function read_config()
    local raw, read_err, errno = SRV.read_file(CONFIG, LIB.UCI_MAX_SIZE)
    if not raw then
        if errno == 2 then return {}, nil, true end
        return nil, read_err or "Cannot read Argon configuration"
    end
    if not raw:match("%S") then return nil, "Argon configuration is empty" end
    -- get() alone cannot distinguish a missing option from a failed UCI RPC.
    -- Read the whole package first: only a successful native parse permits
    -- field defaults or creation of the missing typography section. Unlike
    -- theme_config.snapshot(), this needs no private CLI delta-directory setup.
    local uci = require("luci.model.uci").cursor()
    local sections, err = uci:get_all("argon")
    if type(sections) ~= "table" then return nil, err or "Cannot read Argon configuration" end
    for name, value in pairs(sections) do
        if type(name) ~= "string" or type(value) ~= "table" or value[".name"] ~= name or
            type(value[".type"]) ~= "string" then
            return nil, "Invalid Argon configuration response"
        end
    end
    local section = sections.typography
    if section ~= nil and (type(section) ~= "table" or section[".type"] ~= "typography") then
        return nil, "Invalid Argon typography section"
    end
    return sections, nil, false
end

local function settings_from(section)
    local settings = {}
    for _, key in ipairs(FIELDS) do
        local value = section[key]
        if value == nil then value = DEFAULTS[key] end
        if type(value) ~= "string" then return nil, "Invalid Argon typography setting: " .. key end
        local range = RANGES[key]
        if range and value ~= "" then
            local n = tonumber(value)
            if not n or n ~= n or n < range[1] or n > range[2] or
                key == "font_weight" and not value:match("^%d+$") then
                return nil, "Invalid Argon typography setting: " .. key
            end
        end
        if key == "font_family_custom" and value:find("[^%w%s,'%-]") then
            return nil, "Invalid Argon typography setting: " .. key
        end
        settings[key] = value
    end
    return settings
end

-- Read-only settings observation (4.11.0): no exclusive writer lock. The
-- file read and the UCI package read remain independent checked observations;
-- a failed read is an explicit error and never becomes first-run defaults.
-- Mutations keep the argon-css reservation below.
function M.read_settings()
    local sections, err, missing = read_config()
    if not sections then return nil, err end
    local settings, settings_err = settings_from(sections.typography or {})
    if not settings then return nil, settings_err end
    return settings, nil, { settings_source = sections.typography and "uci" or "defaults", config_missing = missing }
end

-- Single place writing all typography fields to UCI (used by save / reset / bundle import)
function M.save_uci_fields(s)
    return locked_write(function()
        if type(s) ~= "table" then return false, "Invalid Argon typography settings" end
        local fields, fields_err = settings_from(s)
        if not fields then return false, fields_err end
        local sections, err = read_config()
        if not sections then return false, err end
        local uci = require("luci.model.uci").cursor()
        -- Adding an existing named section is not an update on every UCI
        -- implementation. Retain all unknown options in the existing section.
        if not sections.typography then
            local created, create_err = uci:set("argon", "typography", "typography")
            if not created then return false, "Cannot create Argon typography section", nil, { details = create_err } end
        end
        for _, key in ipairs(FIELDS) do
            local saved, save_err = uci:set("argon", "typography", key, fields[key])
            if not saved then
                uci:revert("argon")
                return false, "Cannot save Argon typography", nil, { details = save_err }
            end
        end
        local committed, commit_err = uci:commit("argon")
        if not committed then
            uci:revert("argon")
            return false, "Cannot commit Argon typography", nil, { details = commit_err }
        end
        return true
    end)
end

local function css_block_span(content)
    local first = content:find(MARKER_START, 1, true)
    local last = content:find(MARKER_END, 1, true)
    if not first and not last then return nil end
    if not first or not last or last < first or content:find(MARKER_START, first + #MARKER_START, true) or
        content:find(MARKER_END, last + #MARKER_END, true) then
        return nil, nil, "Incomplete or duplicate Argon typography CSS markers"
    end
    return first, last + #MARKER_END - 1
end

local function read_css()
    local content, err = SRV.read_file(CASCADE_CSS, CSS_MAX_SIZE)
    if not content then return nil, err or "Cannot read Argon stylesheet" end
    if not content:match("%S") then return nil, "Argon stylesheet is empty" end
    return content
end

local function replace_css(original, content)
    if #content > CSS_MAX_SIZE then return false, "Argon stylesheet exceeds size limit" end
    if original == content then return true end
    local stage, stage_err = SRV.stage_file(CASCADE_CSS, content, { mode = "644", suffix = ".pt-typography" })
    if not stage then return false, stage_err end
    -- The lock coordinates Tweaker actors, not an external theme installation
    -- or administrator. Do not publish a candidate over a changed source.
    local current, read_err = read_css()
    if not current or current ~= original then
        SRV.discard_stage(stage)
        return false, read_err or "Argon stylesheet changed during typography update"
    end
    local published, publish_err = SRV.publish_file(stage, CASCADE_CSS)
    if not published then SRV.discard_stage(stage) end
    return published, publish_err
end

-- Read-only CSS observation (4.11.0): unlocked like read_settings. During a
-- live update the API layer reports the busy job instead of serving a
-- migration-time snapshot; this helper itself only reports checked facts.
function M.check_stale()
    local content, err = read_css()
    if not content then return nil, err end
    local first, _, marker_err = css_block_span(content)
    if marker_err then return nil, marker_err end
    return first == nil
end

function M.inject_css(css_block)
    return locked_write(function()
        if type(css_block) ~= "string" then return false, "Argon typography CSS must be text" end
        local block_first, block_last, block_err = css_block_span(css_block)
        if block_err or block_first ~= 1 or block_last ~= #css_block then
            return false, block_err or "Invalid Argon typography CSS block"
        end
        local content, err = read_css()
        if not content then return false, err end
        local first, last, marker_err = css_block_span(content)
        if marker_err then return false, marker_err end
        local replacement
        if first then
            replacement = content:sub(1, first - 1) .. css_block .. content:sub(last + 1)
        else
            local separator = content ~= "" and not content:match("[\r\n]$") and "\n" or ""
            replacement = content .. separator .. css_block .. "\n"
        end
        return replace_css(content, replacement)
    end)
end

function M.remove_css()
    return locked_write(function()
        local content, err = read_css()
        if not content then return false, err end
        local first, last, marker_err = css_block_span(content)
        if marker_err then return false, marker_err end
        if not first then return true end
        -- Remove exactly the owned marker span. Every byte before and after it,
        -- including whitespace, CRLFs and adjacent rules, belongs to the theme.
        return replace_css(content, content:sub(1, first - 1) .. content:sub(last + 1))
    end)
end

function M.apply(settings)
    return locked_write(function()
        local err, uncertain, info
        if settings == nil then settings, err, uncertain, info = M.read_settings()
        elseif type(settings) == "table" then settings, err = settings_from(settings)
        else return false, "Invalid Argon typography settings" end
        if not settings then return false, err, uncertain, info end
        return M.inject_css(LIB.generate_argon_css(settings))
    end)
end

function M.tab_disabled()
    local uci = require("luci.model.uci").cursor()
    return uci:get("podkop-tweaker", "settings", "show_argon_tab") ~= "1"
end

return M
