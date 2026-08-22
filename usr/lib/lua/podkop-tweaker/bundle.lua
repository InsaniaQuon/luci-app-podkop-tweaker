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
    local data = SRV.read_file(path)
    if not data then return true end
    local bfd = io.open(path .. ".bundle-backup", "w")
    if not bfd then return false end
    bfd:write(data)
    bfd:close()
    return true
end

local function write_file(path, content)
    return SRV.write_file_atomic(path, content)
end

local function apply_argon_settings(settings)
    if type(settings) ~= "table" then
        return false, "Invalid argon settings"
    end
    local clamp_str = LIB.clamp_str
    local uci = require("luci.model.uci").cursor()
    local font_size = clamp_str(settings.font_size, 13, 20)
    local font_family = tostring(settings.font_family or "Google Sans")
    if not LIB.ARGON_FONT_FAMILIES[font_family] and font_family ~= "custom" then
        font_family = "Google Sans"
    end
    local font_family_custom = tostring(settings.font_family_custom or ""):gsub("[^%w%s,'%-]", "")
    local font_weight = tostring(settings.font_weight or "400")
    if not font_weight:match("^[0-9]+$") then font_weight = "400" end
    local line_height = clamp_str(settings.line_height, 1.0, 2.0)
    local letter_spacing = clamp_str(settings.letter_spacing, -0.5, 2.0)
    local menu_font_size = clamp_str(settings.menu_font_size, 0.7, 1.2)
    local menu_padding = clamp_str(settings.menu_padding, 5, 20)
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
                local slots = {}
                for i, entry in ipairs(val) do
                    if entry ~= nil and type(entry) ~= "table" then
                        return false, "Invalid slot data in section: " .. key
                    end
                    if type(entry) == "table" then
                        local sub_url = tostring(entry.subscription_url or "")
                        if sub_url ~= "" and not sub_url:match("^https?://") then
                            return false, "Invalid subscription URL in section: " .. key
                        end
                    end
                    slots[i] = entry
                end
                clean[key] = slots
            end
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
    if content == "" then return false, "Empty sing-box config" end
    if #content > 2097152 then return false, "Config too large (max 2MB)" end
    local sys = require("luci.sys")
    local tmp_path = SRV.SINGBOX_CONFIG .. ".tmp-import"
    local tmpfd = io.open(tmp_path, "w")
    if not tmpfd then
        return false, "Cannot write temporary file"
    end
    tmpfd:write(content)
    tmpfd:close()
    local check = sys.exec("sing-box check -c " .. tmp_path .. " 2>&1")
    if check and check ~= "" then
        os.remove(tmp_path)
        return false, "sing-box check failed: " .. check
    end
    local orig = SRV.read_file(SRV.SINGBOX_CONFIG)
    if orig then
        local bfd = io.open(SRV.SINGBOX_BACKUP, "w")
        if bfd then
            bfd:write(orig)
            bfd:close()
        end
    end
    os.rename(tmp_path, SRV.SINGBOX_CONFIG)
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
        if not S.backup_config() then
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
        if not S.backup_stubby_config() then
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
