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

local function update_response(result, attach)
    local response = {}
    for key, value in pairs(result) do
        if key ~= "details" and key ~= "error_details" and key ~= "need_restart" then response[key] = value end
    end
    response.outcomes, response.details = result.details, result.error_details
    if attach then response.unchanged = result.unchanged == 1 or nil end
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
    local result = S.attach_subscription(SRV.SUBS_FILE, SRV.UPDATE_LOG_FILE, SRV.UPDATE_LOG_MAX,
        section_name, slot_index, subscription_url, proxy_name, new_link)
    return update_response(S.finish_subscription_update(result), true)
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
    return update_response(S.finish_subscription_update(result))
end

function M.download_sub_backup()
    require("podkop-tweaker.http").send_download("/etc/config/podkop.sub-backup", "podkop-sub-backup.conf", "Sub backup file not found")
end

return M
