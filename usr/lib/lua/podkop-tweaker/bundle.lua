-- Podkop Tweaker | bundle import/export logic
-- Author: InsaniaQuon

local LIB = require("podkop-tweaker.lib")
local SRV = require("podkop-tweaker.services")
local ARGON = require("podkop-tweaker.argon")
local SCHED = require("podkop-tweaker.subsched")

local S = require("pt-subs-lib")

local M = {}

M.ITEMS = { "podkop", "stubby", "singbox", "fragment", "argon", "tweaker", "subs" }

function M.is_known_item(name)
    for _, v in ipairs(M.ITEMS) do
        if name == v then return true end
    end
    return false
end

function M.read_file(path)
    return SRV.read_file(path)
end

function M.backup_path(path)
    return SRV.backup_to(path, path .. ".bundle-backup")
end

local function write_file(path, content)
    return SRV.write_file_atomic(path, content)
end

local function apply_argon_settings(settings)
    if type(settings) ~= "table" then
        return false, "Invalid argon settings"
    end
    local clamp_str = LIB.clamp_str
    local clean = {
        font_size = clamp_str(settings.font_size, 13, 20),
        font_family = tostring(settings.font_family or "Google Sans"),
        font_family_custom = tostring(settings.font_family_custom or ""):gsub("[^%w%s,'%-]", ""),
        font_weight = tostring(settings.font_weight or "400"),
        line_height = clamp_str(settings.line_height, 1.0, 2.0),
        letter_spacing = clamp_str(settings.letter_spacing, -0.5, 2.0),
        menu_font_size = clamp_str(settings.menu_font_size, 0.7, 1.2),
        menu_padding = clamp_str(settings.menu_padding, 5, 20)
    }
    if not LIB.ARGON_FONT_FAMILIES[clean.font_family] and clean.font_family ~= "custom" then
        clean.font_family = "Google Sans"
    end
    if not clean.font_weight:match("^[0-9]+$") then
        clean.font_weight = "400"
    end
    ARGON.save_uci_fields(clean)
    if not ARGON.apply() then
        return false, "CSS injection failed"
    end
    return true
end

local function apply_subs(data, subs_file)
    if type(data) ~= "table" then
        return false, "Invalid subscriptions data"
    end
    local clean = {}
    for key, val in pairs(data) do
        if key ~= "version" then
            if key == "settings" then
                if val ~= nil and type(val) ~= "table" then
                    return false, "Invalid subscriptions settings"
                end
                clean.settings = val
            elseif type(key) == "string" and key ~= "" and key:match("^[a-zA-Z0-9_%-]+$") then
                if type(val) ~= "table" then
                    return false, "Invalid section data: " .. key
                end
                -- JSON null decodes to nil and makes the array sparse: ipairs would
                -- silently drop slots after the hole. Iterate up to the max numeric
                -- index and normalize holes to false (the app's own empty-slot form).
                local max_n = 0
                for k in pairs(val) do
                    if type(k) == "number" and k > max_n then max_n = k end
                end
                local slots = {}
                for i = 1, max_n do
                    local entry = val[i]
                    if entry ~= nil and type(entry) ~= "table" then
                        return false, "Invalid slot data in section: " .. key
                    end
                    if type(entry) == "table" then
                        local sub_url = tostring(entry.subscription_url or "")
                        if sub_url ~= "" and not sub_url:match("^https?://") then
                            return false, "Invalid subscription URL in section: " .. key
                        end
                        slots[i] = entry
                    else
                        slots[i] = false
                    end
                end
                clean[key] = slots
            end
        end
    end
    -- normalize settings before persisting: interval must be an int within 1..24,
    -- log_display_count within 1..25 (same bounds as api_subs.settings_save)
    if type(clean.settings) == "table" then
        local interval = tonumber(clean.settings.auto_update_interval) or 0
        if interval > 0 then
            interval = math.floor(interval)
            if interval < 1 then interval = 1 end
            if interval > 24 then interval = 24 end
            clean.settings.auto_update_interval = interval
        end
        if type(clean.settings.log_display_count) == "number" then
            local ldc = math.floor(clean.settings.log_display_count)
            if ldc < 1 then ldc = 1 end
            if ldc > 25 then ldc = 25 end
            clean.settings.log_display_count = ldc
        end
    end
    if not M.backup_path(subs_file) then
        return false, "Cannot create backup"
    end
    if not S.write_subs(clean, subs_file) then
        return false, "Cannot write subscriptions file"
    end
    if type(clean.settings) == "table" then
        local interval = tonumber(clean.settings.auto_update_interval) or 0
        local start_time = tostring(clean.settings.auto_update_start or "")
        if interval > 0 and not start_time:match("^%d%d:%d%d$") then
            interval = 0
            start_time = ""
        end
        SCHED.create_auto_update_script()
        SCHED.setup_cron(interval, start_time)
        SCHED.setup_hotplug(clean.settings.auto_update_on_restart == true)
    end
    return true
end

local function apply_singbox_config(content)
    local ok, err = SRV.singbox_content_check(content, "Empty sing-box config")
    if not ok then
        return false, err
    end
    ok, err = SRV.singbox_apply_checked(content, ".tmp-import", "sing-box check failed")
    if not ok then
        return false, err
    end
    return true
end

function M.apply_item(name, item, env)
    if type(item) ~= "table" then
        return false, "Invalid item data"
    end
    if name == "podkop" then
        local c = item.content or ""
        local ok, err = LIB.validate_uci_config(c)
        if not ok then return false, err end
        if not SRV.backup_current(SRV.podkop) then
            return false, "Cannot create backup"
        end
        ok, err = write_file("/etc/config/podkop", c)
        if not ok then return false, err end
        env.restart_podkop = true
        return true
    elseif name == "stubby" then
        local c = item.content or ""
        local ok, err = LIB.validate_uci_config(c)
        if not ok then return false, err end
        if not SRV.backup_current(SRV.stubby) then
            return false, "Cannot create backup"
        end
        ok, err = write_file("/etc/config/stubby", c)
        if not ok then return false, err end
        env.restart_stubby = true
        return true
    elseif name == "singbox" then
        local ok, err = apply_singbox_config(item.content or "")
        if not ok then return false, err end
        env.restart_singbox = true
        return true
    elseif name == "fragment" then
        local c = item.content or ""
        local ok, err = LIB.validate_uci_config(c)
        if not ok then return false, err end
        if not M.backup_path("/etc/config/podkop-fragment") then
            return false, "Cannot create backup"
        end
        ok, err = write_file("/etc/config/podkop-fragment", c)
        if not ok then return false, err end
        return true
    elseif name == "tweaker" then
        local c = item.content or ""
        local ok, err = LIB.validate_uci_config(c)
        if not ok then return false, err end
        if not M.backup_path("/etc/config/podkop-tweaker") then
            return false, "Cannot create backup"
        end
        ok, err = write_file("/etc/config/podkop-tweaker", c)
        if not ok then return false, err end
        return true
    elseif name == "argon" then
        if ARGON.tab_disabled() then
            return false, "Argon tab is disabled"
        end
        return apply_argon_settings(item.settings)
    elseif name == "subs" then
        return apply_subs(item.data, env.subs_file)
    end
    return false, "Unknown item"
end

return M
