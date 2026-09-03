-- Podkop Tweaker | v4.4.0 | 30.08.2026 | clamp_str validation + argon.save_uci_fields single write point

local AR = require("podkop-tweaker.argon")
local LIB = require("podkop-tweaker.lib")

local M = {}

function M.typography()
    if AR.tab_disabled() then
        return { error = "Argon tab is disabled" }
    end
    local settings = AR.read_settings()
    local families = {}
    for k, _ in pairs(LIB.ARGON_FONT_FAMILIES) do
        table.insert(families, k)
    end
    table.sort(families)
    return {
        settings = settings,
        stale = AR.check_stale(),
        font_families = families
    }
end

function M.typography_save(input)
    input = input or {}
    if AR.tab_disabled() then
        return { error = "Argon tab is disabled" }
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
    if not settings.font_weight:match("^[0-9]+$") then
        settings.font_weight = "400"
    end

    AR.save_uci_fields(settings)

    local ok = AR.apply()
    return { success = ok, stale = AR.check_stale() }
end

function M.typography_reset()
    if AR.tab_disabled() then
        return { error = "Argon tab is disabled" }
    end
    AR.save_uci_fields({
        font_size = "",
        font_family = "Google Sans",
        font_family_custom = "",
        font_weight = "400",
        line_height = "",
        letter_spacing = "",
        menu_font_size = "",
        menu_padding = ""
    })
    AR.remove_css()
    return { success = true, stale = true }
end

function M.reinject()
    if AR.tab_disabled() then
        return { error = "Argon tab is disabled" }
    end
    local ok = AR.apply()
    return { success = ok, stale = AR.check_stale() }
end

return M
