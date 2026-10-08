-- Podkop Tweaker | v2.0.1 | 08.10.2026 | User-selected light status defaults
-- Fixed enums/numeric bounds and six-digit HEX keep HTML/CSS metadata safe.

local M = {}
local CONFIG = "podkop-tweaker"
local DEFAULTS = {
    profile = "soft", mono_font_size = "13",
    mono_font_weight = "400", mono_line_height = "1.6",
    color_success_light = "#00be00", color_error_light = "#ff0000", color_warning_light = "#ff8c42",
    color_success_dark = "#00ff00", color_error_dark = "#ff8080", color_warning_dark = "#ffbd42"
}
local BASE_FIELDS = { "profile", "mono_font_size", "mono_font_weight", "mono_line_height" }
local COLOR_FIELDS = {
    "color_success_light", "color_error_light", "color_warning_light",
    "color_success_dark", "color_error_dark", "color_warning_dark"
}
local FIELDS = {}
for _, key in ipairs(BASE_FIELDS) do FIELDS[#FIELDS + 1] = key end
for _, key in ipairs(COLOR_FIELDS) do FIELDS[#FIELDS + 1] = key end

local function value_for(key, raw)
    if type(raw) ~= "string" and type(raw) ~= "number" then return nil end
    local value = tostring(raw)
    if key == "profile" then
        if value == "soft" or value == "contrast" then return value end
    elseif key == "mono_font_size" then
        local n = tonumber(value)
        if value:match("^%d+$") and n >= 12 and n <= 18 then return tostring(n) end
    elseif key == "mono_font_weight" then
        if value == "400" or value == "500" then return value end
    elseif key == "mono_line_height" then
        if value:match("^1%.[3-8]$") then return value end
    elseif key:match("^color_") then
        if value:match("^#%x%x%x%x%x%x$") then return value:lower() end
    end
    return nil
end

-- Bad/missing on-device settings fall back independently, never reach CSS raw.
function M.normalize(settings)
    settings = type(settings) == "table" and settings or {}
    local clean = {}
    for _, key in ipairs(FIELDS) do
        clean[key] = value_for(key, settings[key]) or DEFAULTS[key]
    end
    return clean
end

function M.validate(settings)
    if type(settings) ~= "table" then return nil, "Invalid appearance settings" end
    local clean = {}
    for _, key in ipairs(FIELDS) do
        clean[key] = value_for(key, settings[key])
        if not clean[key] then return nil, "Invalid appearance setting: " .. key end
    end
    return clean
end

function M.read()
    local uci = require("luci.model.uci").cursor()
    local settings = {}
    for _, key in ipairs(FIELDS) do
        settings[key] = uci:get(CONFIG, "appearance", key)
    end
    return M.normalize(settings)
end

local function write_fields(settings, fields)
    local uci = require("luci.model.uci").cursor()
    if not uci:set(CONFIG, "appearance", "appearance") then
        return nil, "Cannot create appearance settings"
    end
    for _, key in ipairs(fields) do
        if not uci:set(CONFIG, "appearance", key, settings[key]) then
            return nil, "Cannot write appearance settings"
        end
    end
    if not uci:commit(CONFIG) then return nil, "Cannot commit appearance settings" end
    return true
end

function M.save(settings)
    local clean, err = M.validate(settings)
    if not clean then return nil, err end
    local ok, write_err = write_fields(clean, FIELDS)
    if not ok then return nil, write_err end
    return clean
end

local function reset_fields(fields)
    local ok, err = write_fields(DEFAULTS, fields)
    if not ok then return nil, err end
    return M.read()
end

function M.reset()
    return reset_fields(BASE_FIELDS)
end

function M.reset_colors()
    return reset_fields(COLOR_FIELDS)
end

return M
