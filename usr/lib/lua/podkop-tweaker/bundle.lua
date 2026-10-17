-- Podkop Tweaker | bundle import/export logic
-- Author: InsaniaQuon

local LIB = require("podkop-tweaker.lib")
local SRV = require("podkop-tweaker.services")
local ARGON = require("podkop-tweaker.argon")
local SCHED = require("podkop-tweaker.subsched")

local S = require("pt-subs-lib")

local M = {}

M.ITEMS = { "podkop", "stubby", "singbox", "fragment", "argon", "tweaker", "subs" }

local UCI_LIMIT = 1048576
-- Podkop is required by the application. Optional components may be absent on
-- a first installation; export records ONLY ENOENT omissions in bundle.omitted.
-- An existing unreadable/empty file is never an optional omission.
local EXPORT_FILES = {
    podkop = { path = SRV.podkop.config, limit = UCI_LIMIT },
    stubby = { path = SRV.stubby.config, limit = UCI_LIMIT, optional = true },
    singbox = { path = SRV.SINGBOX_CONFIG, limit = SRV.SINGBOX_MAX_SIZE, optional = true },
    fragment = { path = "/etc/config/podkop-fragment", limit = UCI_LIMIT, optional = true },
    tweaker = { path = "/etc/config/podkop-tweaker", limit = UCI_LIMIT, optional = true }
}

function M.is_known_item(name)
    for _, v in ipairs(M.ITEMS) do
        if name == v then return true end
    end
    return false
end

function M.read_file(path, limit)
    return SRV.read_file(path, limit)
end

-- item | nil,error,{status,path} | nil,nil,{reason,path,optional}.
-- Hidden Argon is deliberately invisible, rather than an export failure.
function M.export_item(name)
    local file = EXPORT_FILES[name]
    if file then
        local content, err, errno = M.read_file(file.path, file.limit)
        if content == nil then
            if errno == 2 and file.optional then
                return nil, nil, { reason = "not_found", path = file.path, optional = true }
            end
            return nil, errno == 2 and "Selected configuration file not found" or "Cannot read selected configuration file",
                { status = errno == 2 and 404 or 500, path = file.path, details = err }
        end
        if not content:match("%S") then
            return nil, "Selected configuration file is empty; restore or regenerate it before exporting",
                { status = 500, path = file.path }
        end
        return { content = content }
    elseif name == "argon" then
        if ARGON.tab_disabled() then return nil end
        local settings, err, source = ARGON.read_settings()
        if type(settings) ~= "table" or settings.error then
            return nil, "Cannot read selected Argon typography",
                { status = 500, details = err or (type(settings) == "table" and settings.error or nil), unknown = source == true or nil }
        end
        return { settings = settings }
    elseif name == "subs" then
        local subs, err = S.read_subs(SRV.SUBS_FILE)
        if type(subs) ~= "table" then
            return nil, "Cannot read selected subscriptions", { status = 500, path = SRV.SUBS_FILE, details = err }
        end
        return { data = subs }
    end
    return nil, "Unknown item", { status = 400 }
end

function M.backup_path(path)
    return SRV.backup_to(path, path .. ".bundle-backup")
end

local function write_file(path, content)
    return SRV.write_file_atomic(path, content)
end

local function mark_applied(state)
    state.applied = true
end

-- Keep the known disk outcome even if lock release or a later finishing stage
-- fails. env also retains it across the API's per-item exception boundary.
local function locked_item(key, name, env, fn)
    local state = {}
    env.item_states = env.item_states or {}
    env.item_states[name] = state
    local operation_err
    local ok, err, uncertain = SRV.with_lock(key, function()
        local item_ok, item_err, info = fn(state)
        if type(info) == "table" and info ~= state then
            for field, value in pairs(info) do state[field] = value end
        end
        operation_err = item_err or state.error
        state.error = operation_err
        return item_ok, operation_err
    end)
    if ok == nil then
        local lock_err = err or "Cannot acquire or release resource lock"
        if operation_err then
            state.primary_error = state.primary_error or operation_err
            state.primary_details = state.primary_details or state.details
            state.details = tostring(operation_err) .. (state.details and ("\n" .. state.details) or "") .. "\n" .. lock_err
        else
            state.details = (state.details and (state.details .. "\n") or "") .. lock_err
        end
        state.error, state.lock_error = lock_err, lock_err
        -- with_lock's third result is uncertainty, never publication evidence.
        state.unknown = uncertain == true or state.unknown or nil
        return false, lock_err, state
    end
    if state.unknown then return false, operation_err or "Item outcome is unknown", state end
    return ok, err, state
end

local function apply_argon_settings(settings, env)
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
    local weight = tonumber(clean.font_weight)
    if not clean.font_weight:match("^[0-9]+$") or not weight or weight < 300 or weight > 700 then
        clean.font_weight = "400"
    end
    return locked_item("argon-css", "argon", env, function(state)
        local current, read_err, read_info = ARGON.read_settings()
        if type(current) ~= "table" or current.error then
            state.unknown = read_info == true or nil
            state.details = read_err or (type(current) == "table" and current.error or nil)
            return false, "Cannot read current Argon typography: " .. tostring(read_err or
                (type(current) == "table" and current.error) or "unknown error"), state
        end
        local saved, save_err, save_uncertain = ARGON.save_uci_fields(clean)
        state.unknown = save_uncertain == true or state.unknown or nil
        if not saved then
            state.details = save_err
            return false, save_err, state
        end
        mark_applied(state)
        local applied, apply_err, apply_uncertain = ARGON.apply(clean)
        state.unknown = apply_uncertain == true or state.unknown or nil
        if not applied then
            state.details = apply_err
            return false, "Argon settings saved, but CSS injection failed", state
        end
        return true, nil, state
    end)
end

local function copy_table(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, field in pairs(value) do result[key] = copy_table(field) end
    return result
end

local function apply_subs(data, env)
    if type(data) ~= "table" then
        return false, "Invalid subscriptions data"
    end
    -- Preserve version, unknown metadata and keyed fields inside sections,
    -- settings and associations. Normalize only the known numeric slot span.
    local clean = copy_table(data)
    for key, val in pairs(data) do
        if key ~= "version" then
            if key == "settings" then
                if val ~= nil and type(val) ~= "table" then
                    return false, "Invalid subscriptions settings"
                end
            elseif type(key) == "string" and type(val) == "table" then
                -- Non-container extension metadata is preserved, as in the
                -- shared strict state reader. Positional containers are checked.
                -- JSON null decodes to nil and makes the array sparse: ipairs would
                -- silently drop slots after the hole. Iterate up to the max numeric
                -- index and normalize holes to false (the app's own empty-slot form).
                local max_n = 0
                for k in pairs(val) do
                    if type(k) == "number" and k >= 1 and k == math.floor(k) and k > max_n then max_n = k end
                end
                if max_n > 1000 then return false, "Too many subscription slots in section: " .. key end
                local slots = clean[key]
                for i = 1, max_n do
                    local entry = val[i]
                    if entry ~= nil and entry ~= false and type(entry) ~= "table" then
                        return false, "Invalid slot data in section: " .. key
                    end
                    if type(entry) == "table" then
                        if entry.subscription_url ~= nil and type(entry.subscription_url) ~= "string" then
                            return false, "Invalid subscription URL in section: " .. key
                        end
                        local sub_url = entry.subscription_url or ""
                        if sub_url ~= "" and not sub_url:match("^https?://") then
                            return false, "Invalid subscription URL in section: " .. key
                        end
                        slots[i] = copy_table(entry)
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
    return locked_item("subscriptions", "subs", env, function(state)
        local subs_file = env.subs_file or SRV.SUBS_FILE
        local current, read_err = S.read_subs(subs_file)
        if type(current) ~= "table" then
            state.details = read_err
            return false, "Cannot read current subscriptions: " .. tostring(read_err or "unknown error"), state
        end
        local backed_up, backup_err = M.backup_path(subs_file)
        if not backed_up then
            state.details = backup_err
            return false, "Cannot create subscriptions backup: " .. tostring(backup_err or "unknown error"), state
        end
        local written, write_err, applied, unknown = S.write_subs(clean, subs_file)
        if applied == true then mark_applied(state); state.state_saved = true end
        state.unknown = unknown == true or nil
        if not written or unknown == true then
            state.details = write_err
            state.scheduling_required = state.applied or state.unknown or nil
            return false, "Cannot write subscriptions file: " .. tostring(write_err or "unknown error"), state
        end
        if applied ~= true then
            state.unknown, state.scheduling_required = true, true
            return false, "Subscriptions publication was not confirmed", state
        end
        -- A full state import without settings also restores disabled scheduling.
        local settings = type(clean.settings) == "table" and clean.settings or {}
        local interval = tonumber(settings.auto_update_interval) or 0
        local start_time = tostring(settings.auto_update_start or "")
        if interval > 0 and not start_time:match("^%d%d:%d%d$") then
            interval = 0
            start_time = ""
        end
        local ok, err, schedule_partial, schedule_unknown = SCHED.apply(interval, start_time, settings.auto_update_on_restart == true)
        -- The scheduler's legacy third failure result mixes partial application
        -- and missing command/release evidence. Keep it unverified, not applied.
        state.unknown = schedule_unknown == true or (ok ~= true and schedule_partial == true) or state.unknown or nil
        if not ok or state.unknown then
            state.details = err
            state.scheduling_required = true
            return false, "Subscriptions saved, but scheduling failed: " .. tostring(err or "Scheduling outcome is unknown"), state
        end
        return true, nil, state
    end)
end

local function apply_service(name, content, env)
    local result = SRV.apply_service(name, content, { restart = false })
    if type(result) ~= "table" then return false, "Cannot apply service configuration" end
    env.item_states = env.item_states or {}
    env.item_states[name] = result
    if result.success == true and not result.error and not result.unknown then
        if result.unchanged ~= true then
            if result.applied ~= true then
                result.success, result.unknown = false, true
                result.error = "Service configuration publication was not confirmed"
                return false, result.error, result
            end
            env["restart_" .. name] = true
        end
        return true, nil, result
    end
    if result.applied == true and result.restarting ~= true then result.restart_required = true end
    return false, result.error or "Cannot apply service configuration", result
end

local function apply_uci(name, path, key, content, env)
    local valid, validation_err = LIB.validate_uci_config(content)
    if not valid then return false, validation_err end
    return locked_item(key, name, env, function(state)
        local current, read_err, errno = M.read_file(path, UCI_LIMIT)
        if current == nil and errno ~= 2 then
            state.details = read_err
            return false, "Cannot read current configuration: " .. tostring(read_err or path), state
        end
        if current ~= nil then
            local usable = LIB.validate_uci_config(current)
            if usable then
                local backed_up, backup_err = write_file(path .. ".bundle-backup", current)
                if not backed_up then
                    state.details = backup_err
                    return false, "Cannot create backup: " .. tostring(backup_err), state
                end
                state.backup_created = true
            else
                state.warning = "Current configuration is empty or invalid; previous bundle backup was preserved"
            end
        end
        -- Shared locks cover app writers, not administrator/external writes.
        local latest, latest_err, latest_errno = M.read_file(path, UCI_LIMIT)
        if latest == nil and latest_errno ~= 2 then
            state.details = latest_err
            return false, "Cannot re-read current configuration: " .. tostring(latest_err or path), state
        end
        if latest ~= current then return false, "Configuration changed during import; read it again before retrying", state end
        local written, write_err = write_file(path, content)
        if not written then state.details = write_err; return false, write_err, state end
        mark_applied(state)
        return true, nil, state
    end)
end

function M.apply_item(name, item, env)
    env = env or {}
    if type(item) ~= "table" then
        return false, "Invalid item data"
    end
    if name ~= "argon" and name ~= "subs" and item.content ~= nil and type(item.content) ~= "string" then
        return false, "Item content must be text"
    end
    if name == "podkop" then
        return apply_service(name, item.content or "", env)
    elseif name == "stubby" then
        return apply_service(name, item.content or "", env)
    elseif name == "singbox" then
        return apply_service(name, item.content or "", env)
    elseif name == "fragment" then
        return apply_uci(name, "/etc/config/podkop-fragment", "singbox", item.content or "", env)
    elseif name == "tweaker" then
        return apply_uci(name, "/etc/config/podkop-tweaker", "tweaker", item.content or "", env)
    elseif name == "argon" then
        if ARGON.tab_disabled() then
            return false, "Argon tab is disabled"
        end
        return apply_argon_settings(item.settings, env)
    elseif name == "subs" then
        return apply_subs(item.data, env)
    end
    return false, "Unknown item"
end

return M
