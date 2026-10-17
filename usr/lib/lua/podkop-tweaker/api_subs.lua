-- Podkop Tweaker | v4.2.0 | 23.08.2026 | V2 pure handlers: args in -> response table out; HTTP layer moved to controller adapter
-- Hybrid exception: download_sub_backup delegates to the bounded download transport.

local SRV = require("podkop-tweaker.services")
local LIB = require("podkop-tweaker.lib")
local SCHED = require("podkop-tweaker.subsched")
local S = require("pt-subs-lib")
local NET = require("podkop-tweaker.net")

local M = {}

local function with_subscriptions(fn)
    local response, progress = nil, {}
    local result, err, uncertain = SRV.with_lock("subscriptions", function()
        response = fn(progress)
        return response
    end)
    if result then return result end
    response = response or {}
    response.success = false
    response.error = response.error or "Subscription lock failed"
    response.details = (response.details and (response.details .. "\n") or "") .. tostring(err)
    response.applied = response.applied or progress.applied or nil
    response.settings_saved = response.settings_saved or progress.settings_saved or nil
    response.unknown = uncertain or response.unknown or nil
    return response
end

local function restart_applied(response)
    local observed
    local restart, lock_err, uncertain = SRV.with_lock("podkop", function()
        observed = SRV.restart_service("podkop")
        return observed
    end)
    if not restart then
        restart = observed or {}
        restart.success = false
        restart.error = restart.error or (restart.restarting and "Podkop restart requested, but lock release failed" or "Podkop restart lock failed")
        restart.details = (restart.details and (restart.details .. "\n") or "") .. tostring(lock_err)
        restart.unknown = uncertain or nil
    end
    for key, value in pairs(restart) do response[key] = value end
    response.applied = true
    if restart.success ~= true then
        response.success = false
        response.restart_required = restart.restarting ~= true or nil
        local logged, log_err, log_applied, log_unknown = S.append_log(SRV.UPDATE_LOG_FILE, SRV.UPDATE_LOG_MAX,
            os.date("%H:%M %d.%m.%Y") .. "|manual|updated=" .. (response.updated or 1)
            .. "|unchanged=" .. (response.unchanged or 0) .. "|failed=" .. math.max(1, response.failed or 0)
            .. "\n  service:\n    podkop: failed (" .. S.clean_log_field(restart.error or "Restart failed") .. ")")
        if not logged then
            response.log_applied = log_applied
            response.unknown = response.unknown or log_unknown
            response.details = (response.details and (response.details .. "\n") or "")
                .. "Cannot write failure log: " .. tostring(log_err)
        end
    end
    return response
end

function M.subscription_state()
    local subs, err = S.read_subs(SRV.SUBS_FILE)
    if not subs then return { error = err } end
    local sections = S.get_proxy_sections()

    local result = {}
    for _, sec in ipairs(sections) do
        local sec_data = {
            name = sec.name,
            proxy_config_type = sec.proxy_config_type,
            slots = {}
        }
        local sec_subs, slots_err = S.subscription_slots(subs, sec.name)
        if not sec_subs then return { error = slots_err } end
        local max_n, count_err = S.slot_count(sec.proxy_links)
        if not max_n then return { error = count_err } end
        for i = 1, max_n do
            local link = sec.proxy_links[i]
            if link ~= nil then
                table.insert(sec_data.slots, {
                    index = i - 1,
                    proxy = S.parse_proxy_link(link),
                    subscription = sec_subs[i] or nil
                })
            end
        end
        table.insert(result, sec_data)
    end

    return { sections = result }
end

function M.subscription_fetch(sub_url)
    if sub_url == "" then
        return { error = "URL is required" }
    end
    if not NET.valid_url(sub_url) then
        return { error = "Only HTTP(S) URLs allowed" }
    end

    local http_warning = sub_url:match("^http://") and true or false

    local raw, download_err = NET.fetch(sub_url, S.SUB_MAX_SIZE, 15, "sing-box")
    if not raw then return { error = "Failed to download subscription", details = download_err } end
    local proxies, parse_err = S.parse_subscription_raw(raw)
    if parse_err then return { error = parse_err } end

    if #proxies == 0 then
        return { error = "No proxy links found in subscription" }
    end

    return { success = true, proxies = proxies, http_warning = http_warning }
end

function M.subscription_attach(section_name, slot_index, subscription_url, proxy_name, new_link)
    slot_index = tonumber(slot_index or "-1")

    if not slot_index or slot_index < 0 or slot_index > 999 or slot_index ~= math.floor(slot_index) then
        return { error = "Missing required parameters" }
    end

    if section_name == "" or new_link == "" then
        return { error = "Missing required parameters" }
    end
    if not LIB.sanitize_section_name(section_name) then
        return { error = "Invalid section name" }
    end
    local valid_link, link_err = S.validate_proxy_link(new_link)
    if not valid_link then return { error = link_err } end
    if not NET.valid_url(subscription_url) then return { error = "Only HTTP(S) URLs allowed" } end
    if proxy_name == nil then proxy_name = "" end
    if type(proxy_name) ~= "string" or #proxy_name > 1024 then return { error = "Invalid proxy name" } end

    local config_applied = false
    local response = with_subscriptions(function(progress)
        local subs, read_err = S.read_subs(SRV.SUBS_FILE)
        if not subs then return { error = read_err } end
        local slots, slots_err = S.subscription_slots(subs, section_name)
        if not slots then return { error = slots_err } end
        local section
        for _, sec in ipairs(S.get_proxy_sections()) do
            if sec.name == section_name then section = sec; break end
        end
        if not section then return { error = "Section not found or not a proxy section" } end
        local current_link = section.proxy_links[slot_index + 1]
        if type(current_link) ~= "string" then return { error = "Proxy slot not found" } end

        local state_applied = false
        local function apply_attachment()
            local live_link, live_err = S.current_proxy_link(section_name, section.proxy_config_type, slot_index)
            if not live_link then return { error = live_err } end
            if live_link ~= current_link then return { error = "Proxy slot changed; refresh before attaching" } end
            local entry = type(slots[slot_index + 1]) == "table" and slots[slot_index + 1] or {}
            entry.subscription_url, entry.proxy_name = subscription_url, proxy_name
            entry.last_updated = os.date("%H:%M %d.%m.%Y") .. " (manual)"
            for i = 1, slot_index do if slots[i] == nil then slots[i] = false end end
            slots[slot_index + 1], subs[section_name] = entry, slots
            local stage, stage_err = S.stage_subs(subs, SRV.SUBS_FILE)
            if not stage then return { error = "Failed to save data", details = stage_err } end
            if current_link ~= new_link then
                local replaced, replace_err, replace_applied, replace_unknown = S.replace_proxy_link(section_name, section.proxy_config_type,
                    slot_index, new_link, "/etc/config/podkop.sub-backup", current_link)
                config_applied = replaced or replace_applied == true
                progress.applied = config_applied or nil
                if not replaced then
                    SRV.discard_stage(stage)
                    return { error = replace_err, applied = config_applied or nil, restart_required = config_applied or nil, unknown = replace_unknown }
                end
            end
            local published, publish_err = SRV.publish_file(stage, SRV.SUBS_FILE)
            if not published then
                SRV.discard_stage(stage)
                return { success = false, error = "Failed to save data", details = publish_err,
                    applied = config_applied or nil, restart_required = config_applied or nil }
            end
            state_applied = true
            progress.applied = true
            return { success = true }
        end
        local observed
        local saved, config_err, uncertain = SRV.with_lock("podkop", function()
            observed = apply_attachment()
            return observed
        end)
        if not saved then
            observed = observed or {}
            observed.success = false
            observed.error = observed.error or "Podkop lock failed"
            observed.details = (observed.details and (observed.details .. "\n") or "") .. tostring(config_err)
            observed.applied = config_applied or state_applied or nil
            observed.restart_required = config_applied or nil
            observed.unknown = uncertain or observed.unknown or nil
            return observed
        end
        if saved.error then return saved end
        local changed = current_link ~= new_link
        local log_text = os.date("%H:%M %d.%m.%Y") .. "|manual|updated=0|unchanged=1|failed=0"
            .. "\n  " .. section_name .. ":\n    " .. S.clean_log_field(proxy_name) .. ": unchanged"
        if changed then
            log_text = os.date("%H:%M %d.%m.%Y") .. "|manual|updated=1|unchanged=0|failed=0"
                .. "\n  " .. section_name .. ":\n    " .. S.clean_log_field(proxy_name) .. ": updated"
        end
        local logged, log_err, log_applied, log_unknown = S.append_log(SRV.UPDATE_LOG_FILE, SRV.UPDATE_LOG_MAX, log_text)
        if not logged then
            return { success = false, error = "Failed to write subscription update log", details = log_err,
                applied = true, restart_required = changed or nil, log_applied = log_applied, unknown = log_unknown }
        end
        return changed and { success = true } or { success = true, unchanged = true }
    end)
    if config_applied and response.success == true then return restart_applied(response) end
    if config_applied then response.applied, response.restart_required = true, true end
    return response
end

function M.subscription_detach(section_name, slot_index)
    slot_index = tonumber(slot_index or "-1")

    if not slot_index or slot_index < 0 or slot_index > 999 or slot_index ~= math.floor(slot_index) or section_name == "" then
        return { error = "Missing required parameters" }
    end
    if not LIB.sanitize_section_name(section_name) then
        return { error = "Invalid section name" }
    end

    return with_subscriptions(function(progress)
        local subs, read_err = S.read_subs(SRV.SUBS_FILE)
        if not subs then return { error = read_err } end
        local slots, slots_err = S.subscription_slots(subs, section_name)
        if not slots then return { error = slots_err } end
        if slots[slot_index + 1] then
            slots[slot_index + 1] = nil
            local saved, save_err, applied, unknown = S.write_subs(subs, SRV.SUBS_FILE)
            progress.applied = saved or applied or nil
            if not saved then return { error = "Failed to save data", details = save_err, applied = applied, unknown = unknown } end
        end
        return { success = true }
    end)
end

function M.settings_read()
    local subs, err = S.read_subs(SRV.SUBS_FILE)
    if not subs then return { error = err } end
    local settings = subs.settings or {}

    return {
        auto_update_interval = settings.auto_update_interval or 0,
        auto_update_start = settings.auto_update_start or "",
        auto_update_on_restart = settings.auto_update_on_restart or false,
        log_display_count = settings.log_display_count or 10
    }
end

function M.settings_save(interval_raw, start_time, on_restart, log_display_raw, log_only)
    local interval = tonumber(interval_raw or "0") or 0
    local log_display = tonumber(log_display_raw or "10") or 10
    if log_display < 1 then log_display = 1 end
    if log_display > 25 then log_display = 25 end
    log_display = math.floor(log_display)

    if log_only ~= true and interval > 0 then
        if interval < 1 or interval > 24 or interval ~= math.floor(interval) then
            return { error = "Interval must be 1-24 hours" }
        end
        if type(start_time) ~= "string" or not start_time:match("^%d%d:%d%d$") then
            return { error = "Invalid start time, use HH:MM" }
        end
        local sh = tonumber(start_time:sub(1, 2))
        local sm = tonumber(start_time:sub(4, 5))
        if not sh or sh > 23 or not sm or sm > 59 then
            return { error = "Invalid start time value" }
        end
    else
        interval = 0
        start_time = ""
    end

    return with_subscriptions(function(progress)
        local subs, read_err = S.read_subs(SRV.SUBS_FILE)
        if not subs then return { error = read_err } end
        subs.settings = subs.settings or {}
        subs.settings.log_display_count = log_display
        if log_only ~= true then
            subs.settings.auto_update_interval = interval
            subs.settings.auto_update_start = start_time
            subs.settings.auto_update_on_restart = on_restart == true
        end
        local saved, save_err, applied, unknown = S.write_subs(subs, SRV.SUBS_FILE)
        progress.applied = saved or applied or nil
        progress.settings_saved = progress.applied
        if not saved then return { error = "Failed to save settings", details = save_err, applied = applied,
            settings_saved = applied, unknown = unknown } end
        if log_only == true then return { success = true } end
        local ok, err = SCHED.apply(interval, start_time, on_restart == true)
        if not ok then
            return { success = false, settings_saved = true, applied = true,
                error = "Settings saved, but scheduling failed", details = err }
        end
        return { success = true }
    end)
end

function M.auto_update_status()
    local settings = M.settings_read()
    if settings.error then return settings end
    return SCHED.status(settings, SRV.UPDATE_LOG_FILE)
end

function M.update_all()
    local result = S.update_all_subscriptions(SRV.SUBS_FILE, SRV.UPDATE_LOG_FILE, SRV.UPDATE_LOG_MAX, "manual")
    local response = {
        success = result.success == true,
        updated = result.updated,
        unchanged = result.unchanged,
        failed = result.failed,
        skipped = result.skipped,
        restarted = false,
        error = result.error,
        details = result.error_details,
        applied = result.applied,
        unknown = result.unknown,
        log_applied = result.log_applied,
        restart_required = result.restart_required,
        outcomes = result.details
    }
    if result.success == true and result.need_restart then
        response = restart_applied(response)
        response.restarted = response.success == true
    end
    return response
end

function M.download_sub_backup()
    require("podkop-tweaker.http").send_download("/etc/config/podkop.sub-backup", "podkop-sub-backup.conf", "Sub backup file not found")
end

return M
