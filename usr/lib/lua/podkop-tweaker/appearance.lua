-- Podkop Tweaker | v2.0.1 | 08.10.2026 | User-selected light status defaults
-- Fixed enums/numeric bounds and six-digit HEX keep HTML/CSS metadata safe.

local M = {}
local SRV = require("podkop-tweaker.services")
local LIB = require("podkop-tweaker.lib")
local CONFIG = "podkop-tweaker"
local CONFIG_PATH = "/etc/config/" .. CONFIG
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
    -- Render-time metadata must always be a safe table, even while UCI/RPC is
    -- unavailable. Writable forms and mutations must use read_checked instead.
    local ok, settings = pcall(function()
        local uci = require("luci.model.uci").cursor()
        local values = {}
        for _, key in ipairs(FIELDS) do values[key] = uci:get(CONFIG, "appearance", key) end
        return values
    end)
    return M.normalize(ok and settings or nil)
end

function M.with_lock(fn)
    return SRV.with_lock("tweaker", fn)
end

local function read_section()
    local raw, read_err, errno = SRV.read_file(CONFIG_PATH, LIB.UCI_MAX_SIZE)
    if raw == nil then
        if errno == 2 then return {}, nil, { settings_source = "defaults", config_missing = true } end
        return nil, read_err or "Cannot read Tweaker configuration"
    end
    if not raw:match("%S") then return nil, "Tweaker configuration is empty" end
    local uci = require("luci.model.uci").cursor()
    local sections, err = uci:get_all(CONFIG)
    if type(sections) ~= "table" then return nil, err or "Cannot read Tweaker configuration" end
    for name, section in pairs(sections) do
        if type(name) ~= "string" or name == "" or type(section) ~= "table" or
            section[".name"] ~= name or type(section[".type"]) ~= "string" or section[".type"] == "" then
            return nil, "Invalid Tweaker configuration response"
        end
    end
    local section = sections.appearance
    if section ~= nil and section[".type"] ~= "appearance" then return nil, "Invalid appearance section" end
    return section or {}, nil, { settings_source = section and "uci" or "defaults", config_missing = false }
end

local function checked_settings(section)
    local settings = {}
    for _, key in ipairs(FIELDS) do
        local value = section[key]
        if value == nil then settings[key] = DEFAULTS[key]
        else
            if type(value) ~= "string" then return nil, "Invalid appearance setting: " .. key end
            settings[key] = value_for(key, value)
            if not settings[key] then return nil, "Invalid appearance setting: " .. key end
        end
    end
    return settings
end

-- settings,nil,{settings_source,config_missing} | nil,error[,failure metadata].
-- A successful native package read permits missing-field defaults. Release
-- failure returns unknown=true without settings or proof of disk application.
function M.read_checked()
    local primary_err
    local ok, settings, err, source = pcall(M.with_lock, function()
        local section, read_err, metadata = read_section()
        if not section then primary_err = read_err; return nil, read_err end
        local values, values_err = checked_settings(section)
        if not values then primary_err = values_err; return nil, values_err end
        return values, nil, metadata
    end)
    if not ok then return nil, tostring(settings) end
    if settings == nil and source == true then
        return nil, primary_err or err, { unknown = true, lock_error = err }
    end
    if settings == nil then return nil, err end
    return settings, nil, source
end

local function read_saved()
    local settings, err, source = M.read_checked()
    if not settings then return nil, err, source end
    -- Missing configuration/fields are legitimate on the initial read. After
    -- a confirmed commit, a missing package or section is a failed readback,
    -- not a new first run that can be reported as a successful default save.
    if source.config_missing then return nil, "Saved Tweaker configuration is missing" end
    if source.settings_source ~= "uci" then return nil, "Saved appearance section is missing" end
    return settings, nil, source
end

local function write_fields(settings, fields, section, state)
    local uci = require("luci.model.uci").cursor()
    -- Re-adding an existing named section can replace its unknown options or
    -- fail on native UCI. Only create a positively absent appearance section.
    if section[".type"] == nil then
        local created, create_err = uci:set(CONFIG, "appearance", "appearance")
        if not created then state.details = create_err; return nil, "Cannot create appearance settings" end
    end
    for _, key in ipairs(fields) do
        local saved, save_err = uci:set(CONFIG, "appearance", key, settings[key])
        if not saved then
            state.details = save_err
            uci:revert(CONFIG)
            return nil, "Cannot write appearance settings"
        end
    end
    local committed, commit_err = uci:commit(CONFIG)
    if not committed then
        state.details = commit_err
        uci:revert(CONFIG)
        return nil, "Cannot commit appearance settings"
    end
    state.uci_saved = true
    return true
end

local function change(fn)
    local state = { uci_saved = false }
    local primary_err, operation_info
    local ok, settings, err, release_failed = pcall(M.with_lock, function()
        local values, values_err, info = fn(state)
        primary_err, operation_info = values_err, info
        return values, values_err, info
    end)
    if ok and release_failed ~= true and type(settings) == "table" then return settings, nil, state end
    if not ok then err = tostring(settings) end
    if type(operation_info) == "table" then
        if operation_info.unknown == true then state.unknown = true end
        if operation_info.lock_error then state.lock_error = operation_info.lock_error end
        if operation_info.details ~= nil and state.details == nil then state.details = operation_info.details end
    end
    if release_failed == true then
        state.unknown, state.lock_error = true, err
        err = primary_err or err
    end
    if state.uci_saved then state.partial, state.applied = true, true end
    return nil, err or "Cannot change appearance settings", state
end

-- Accept a partial selection, but merge it with a checked current read while
-- holding the same resource lock as full Tweaker bundle imports.
function M.save(input)
    if type(input) ~= "table" then return nil, "Invalid appearance settings" end
    return change(function(state)
        local section, read_err = read_section()
        if not section then return nil, read_err end
        local settings, settings_err = checked_settings(section)
        if not settings then return nil, settings_err end
        for _, key in ipairs(FIELDS) do if input[key] ~= nil then settings[key] = input[key] end end
        local clean, validation_err = M.validate(settings)
        if not clean then return nil, validation_err end
        local written, write_err = write_fields(clean, FIELDS, section, state)
        if not written then return nil, write_err end
        -- Commit success does not make a failed readback into writable defaults.
        return read_saved()
    end)
end

local function reset_fields(fields)
    return change(function(state)
        local section, read_err = read_section()
        if not section then return nil, read_err end
        -- Explicit resets may repair their own invalid fields. They never
        -- rewrite malformed values in the other field group or unknown options.
        local written, write_err = write_fields(DEFAULTS, fields, section, state)
        if not written then return nil, write_err end
        return read_saved()
    end)
end

function M.reset()
    return reset_fields(BASE_FIELDS)
end

function M.reset_colors()
    return reset_fields(COLOR_FIELDS)
end

return M
