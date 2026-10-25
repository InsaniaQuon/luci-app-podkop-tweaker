-- Podkop Tweaker | v4.12.0 | 24.10.2026 | Centralized UI visibility gate
-- Single decision point for hiding optional tools. Flags live in the existing
-- podkop-tweaker settings UCI section, survive self-update with the complete
-- file and are backed up by the tweaker bundle item. Argon keeps its published
-- contract; Fragment tools are hidden by default because the focused bench
-- (podkop-engine.md) shows no ClientHello fragmentation effect on the tested
-- REALITY path.

local M = {}

local FLAGS = {
    argon_tab = { option = "show_argon_tab", default = "0" },
    fragment_tools = { option = "show_fragment_tools", default = "0" }
}

local function flag(key)
    local spec = FLAGS[key]
    if not spec then return nil, "Unknown visibility flag: " .. tostring(key) end
    local uci = require("luci.model.uci").cursor()
    local value = uci:get("podkop-tweaker", "settings", spec.option)
    if value == "1" or value == "true" then return true end
    if value == nil or value == "" or value == "0" or value == "false" then return false end
    return false, "Invalid " .. spec.option .. " value: " .. tostring(value)
end

function M.argon_tab()
    return flag("argon_tab") == true
end

function M.fragment_tools()
    return flag("fragment_tools") == true
end

function M.enabled(key)
    if key == "argon_tab" then return M.argon_tab() end
    if key == "fragment_tools" then return M.fragment_tools() end
    return false
end

function M.disabled(key)
    return not M.enabled(key)
end

return M
