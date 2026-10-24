-- Podkop Tweaker | v4.6.0 | 08.10.2026 | Appearance colors with independent reset

local AR = require("podkop-tweaker.argon")
local LIB = require("podkop-tweaker.lib")
local THEME = require("podkop-tweaker.theme")
local APPEARANCE = require("podkop-tweaker.appearance")

local M = {}

local function failure_metadata(response, uncertain, info)
    if uncertain == true then response.unknown = true end
    if type(info) ~= "table" then return end
    if info.unknown == true then response.unknown = true end
    if info.lock_error then response.lock_error = info.lock_error end
    if info.details ~= nil and response.details == nil then response.details = info.details end
end

local function with_typography(fn)
    local response = { success = false }
    local ok, result, err, uncertain = pcall(AR.with_lock, function()
        local outcome = fn(response)
        if type(outcome) == "table" then response = outcome end
        return outcome
    end)
    if ok and uncertain ~= true and type(result) == "table" then return result end
    response.success = false
    local lock_err = (ok and err or result) or "Cannot lock Argon typography"
    if response.error or uncertain == true then response.lock_error = lock_err end
    if not response.error then response.error = lock_err end
    if uncertain == true then
        response.unknown = true
        response.settings, response.stale, response.font_families = nil, nil, nil
        response.settings_source, response.config_missing = nil, nil
    end
    if response.uci_saved or response.css_applied then
        response.partial, response.applied = true, true
    end
    return response
end

local function css_result(response, ok, err, uncertain, info)
    response.css_applied = ok == true
    if not ok then response.error = err or "Cannot apply Argon typography CSS" end
    failure_metadata(response, uncertain, info)
    local stale, stale_err, stale_uncertain, stale_info = AR.check_stale()
    if stale == nil then
        response.stale_error = stale_err or "Cannot read Argon stylesheet status"
        if not response.error then response.error = response.stale_error end
        if type(stale_info) == "table" then response.stale_details = stale_info.details end
        failure_metadata(response, stale_uncertain, stale_info)
    elseif not response.unknown then
        response.stale = stale
    end
    response.success = ok == true and response.error == nil and not response.unknown
    if not response.success and (response.uci_saved or response.css_applied) then
        response.partial, response.applied = true, true
    end
    return response
end

-- A queued/running theme job makes read-only typography observations busy:
-- mid-migration absence must not surface as first-run defaults, and the CSS
-- marker state is not stable while a worker reinjects it.
local function theme_job_active()
    local active = require("podkop-tweaker.theme_worker").active_job()
    return active ~= nil
end

function M.typography()
    if AR.tab_disabled() then
        return { error = "Argon tab is disabled" }
    end
    if theme_job_active() then
        return { error = "A theme update is in progress" }
    end
    local settings, err, source, info = AR.read_settings()
    if not settings then
        local response = { error = err }
        failure_metadata(response, source, info)
        return response
    end
    local stale, stale_err, uncertain, stale_info = AR.check_stale()
    if stale == nil then
        local response = { error = stale_err or "Cannot read Argon stylesheet status" }
        failure_metadata(response, uncertain, stale_info)
        return response
    end
    local families = {}
    for k in pairs(LIB.ARGON_FONT_FAMILIES) do table.insert(families, k) end
    table.sort(families)
    return { settings = settings, stale = stale, font_families = families,
        settings_source = source.settings_source, config_missing = source.config_missing }
end

function M.typography_save(input)
    if AR.tab_disabled() then
        return { error = "Argon tab is disabled" }
    end
    if input == nil then input = {} end
    if type(input) ~= "table" then return { success = false, error = "Invalid typography settings" } end
    for _, key in ipairs({ "font_size", "font_family", "font_family_custom", "font_weight",
        "line_height", "letter_spacing", "menu_font_size", "menu_padding" }) do
        if input[key] ~= nil and type(input[key]) ~= "string" then
            return { success = false, error = "Invalid typography setting: " .. key }
        end
    end

    local clamp = LIB.clamp_str
    local settings = {
        font_size = clamp(input.font_size or "", 13, 20),
        font_family = input.font_family or "Google Sans",
        font_family_custom = (input.font_family_custom or ""):gsub("[^%w%s,'%-]", ""),
        font_weight = input.font_weight or "400",
        line_height = clamp(input.line_height or "", 1.0, 2.0),
        letter_spacing = clamp(input.letter_spacing or "", -0.5, 2.0),
        menu_font_size = clamp(input.menu_font_size or "", 0.7, 1.2),
        menu_padding = clamp(input.menu_padding or "", 5, 20)
    }
    -- dropdown contract: unknown family names are stored verbatim (see api_argon_spec);
    -- generate_argon_css omits unknown families from CSS safely
    local weight = tonumber(settings.font_weight)
    if not settings.font_weight:match("^[0-9]+$") or not weight or weight < 300 or weight > 700 then
        settings.font_weight = "400"
    end

    return with_typography(function(response)
        response.uci_saved, response.css_applied = false, false
        local saved, save_err, uncertain, info = AR.save_uci_fields(settings)
        if not saved then
            response.error = save_err
            failure_metadata(response, uncertain, info)
            return response
        end
        response.uci_saved = true
        -- Apply exactly the committed values under the same resource lock;
        -- a failed re-read must never generate a default-filled CSS block.
        return css_result(response, AR.apply(settings))
    end)
end

function M.typography_reset()
    if AR.tab_disabled() then
        return { error = "Argon tab is disabled" }
    end
    return with_typography(function(response)
        response.uci_saved, response.css_applied = false, false
        local saved, save_err, uncertain, info = AR.save_uci_fields({
            font_size = "", font_family = "Google Sans", font_family_custom = "", font_weight = "400",
            line_height = "", letter_spacing = "", menu_font_size = "", menu_padding = ""
        })
        if not saved then
            response.error = save_err
            failure_metadata(response, uncertain, info)
            return response
        end
        response.uci_saved = true
        return css_result(response, AR.remove_css())
    end)
end

function M.reinject()
    if AR.tab_disabled() then
        return { error = "Argon tab is disabled" }
    end
    return with_typography(function(response)
        response.uci_saved, response.css_applied = false, false
        return css_result(response, AR.apply())
    end)
end

local function appearance_result(settings, err, state)
    if settings then return { success = true, settings = settings } end
    local response = { success = false, error = err }
    if type(state) == "table" and state.uci_saved then
        response.uci_saved, response.partial, response.applied = true, true, true
    end
    failure_metadata(response, false, state)
    return response
end

function M.appearance()
    if AR.tab_disabled() then return { error = "Argon tab is disabled" } end
    local settings, err, source = APPEARANCE.read_checked()
    if not settings then return appearance_result(nil, err, source) end
    return { settings = settings, settings_source = source.settings_source, config_missing = source.config_missing }
end

function M.appearance_save(input)
    if AR.tab_disabled() then return { error = "Argon tab is disabled" } end
    if type(input) ~= "table" then return { error = "Invalid appearance settings" } end
    return appearance_result(APPEARANCE.save(input))
end

function M.appearance_reset()
    if AR.tab_disabled() then return { error = "Argon tab is disabled" } end
    return appearance_result(APPEARANCE.reset())
end

function M.appearance_colors_reset()
    if AR.tab_disabled() then return { error = "Argon tab is disabled" } end
    return appearance_result(APPEARANCE.reset_colors())
end

function M.theme_check(force_raw)
    return THEME.check(force_raw == true or force_raw == "1")
end

-- 4.11.0: the synchronous theme pipeline is gone. Requests without the async
-- marker (old 4.10.5 tabs) fail fast instead of blocking a CGI handler; the
-- reloaded page drives the queued job protocol with a client-generated ID.
function M.theme_update(input)
    input = type(input) == "table" and input or {}
    if input.async ~= "1" and input.async ~= 1 and input.async ~= true then
        return { success = false, error = "Reload the Podkop Tweaker page to update the theme" }
    end
    return require("podkop-tweaker.theme_worker").admit(input.restart_id)
end

function M.theme_job_status(id)
    return require("podkop-tweaker.theme_worker").status(id)
end

return M
