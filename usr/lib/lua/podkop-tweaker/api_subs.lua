-- Podkop Tweaker | Subscriptions + auto-update settings API handlers
-- Author: InsaniaQuon

local H = require("podkop-tweaker.http")
local SRV = require("podkop-tweaker.services")
local LIB = require("podkop-tweaker.lib")
local SCHED = require("podkop-tweaker.subsched")
local S = require("pt-subs-lib")

local M = {}

function M.subscription_state()
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()

    local sections = S.get_proxy_sections()
    local subs = S.read_subs(SRV.SUBS_FILE)

    local result = {}
    for _, sec in ipairs(sections) do
        local sec_data = {
            name = sec.name,
            proxy_config_type = sec.proxy_config_type,
            slots = {}
        }
        local sec_subs = subs[sec.name] or {}
        for i, link in ipairs(sec.proxy_links) do
            local proxy = S.parse_proxy_link(link)
            table.insert(sec_data.slots, {
                index = i - 1,
                proxy = proxy,
                subscription = sec_subs[i] or nil
            })
        end
        table.insert(result, sec_data)
    end

    http.write_json({ sections = result })
end

function M.subscription_fetch()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()

    local ok, err = pcall(function()
        local sys = require("luci.sys")
        local sub_url = http.formvalue("url") or ""
        if sub_url == "" then
            http.write_json({ error = "URL is required" })
            return
        end
        if not sub_url:match("^https?://") then
            http.write_json({ error = "Only HTTP(S) URLs allowed" })
            return
        end

        local http_warning = sub_url:match("^http://") and true or false

        local safe_url = S.shell_escape(sub_url)
        local tmp = sys.exec("mktemp /tmp/pt-sub-XXXXXX 2>/dev/null"):match("%S+") or "/tmp/pt-sub-" .. os.time()
        sys.exec("curl -sL -m 15 -A 'sing-box' -o " .. tmp .. " " .. safe_url .. " 2>/dev/null")

        local fd = io.open(tmp, "r")
        if not fd then
            http.write_json({ error = "Failed to download subscription" })
            return
        end
        local raw = fd:read("*a")
        fd:close()
        os.remove(tmp)

        local proxies = S.parse_subscription_raw(raw)

        if #proxies == 0 then
            http.write_json({ error = "No proxy links found in subscription" })
            return
        end

        http.write_json({ success = true, proxies = proxies, http_warning = http_warning })
    end)

    if not ok then
        http.prepare_content("application/json")
        http.write_json({ error = "Internal error" })
    end
end

function M.subscription_attach()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()

    local ok, err = pcall(function()
        local sys = require("luci.sys")
        local section_name = http.formvalue("section") or ""
        local slot_index = tonumber(http.formvalue("index") or "-1")
        local subscription_url = http.formvalue("subscription_url") or ""
        local proxy_name = http.formvalue("proxy_name") or ""
        local new_link = http.formvalue("link") or ""

        if not slot_index or slot_index < 0 or slot_index > 999 then
            http.write_json({ error = "Missing required parameters" })
            return
        end

        if section_name == "" or new_link == "" then
            http.write_json({ error = "Missing required parameters" })
            return
        end
        if not LIB.sanitize_section_name(section_name) then
            http.write_json({ error = "Invalid section name" })
            return
        end
        if not new_link:match("^%w+://") then
            http.write_json({ error = "Invalid proxy link format" })
            return
        end

        local sections = S.get_proxy_sections()
        local proxy_type = nil
        local current_links = nil
        for _, sec in ipairs(sections) do
            if sec.name == section_name then
                proxy_type = sec.proxy_config_type
                current_links = sec.proxy_links
                break
            end
        end
        if not proxy_type then
            http.write_json({ error = "Section not found or not a proxy section" })
            return
        end

        local current_link = current_links and current_links[slot_index + 1] or ""
        if current_link == new_link then
            local subs = S.read_subs(SRV.SUBS_FILE)
            if not subs[section_name] then subs[section_name] = {} end
            while #subs[section_name] < slot_index + 1 do
                table.insert(subs[section_name], false)
            end
            subs[section_name][slot_index + 1] = {
                subscription_url = subscription_url,
                proxy_name = proxy_name,
                last_updated = os.date("%H:%M %d.%m.%Y") .. " (manual)"
            }
            if not S.write_subs(subs, SRV.SUBS_FILE) then
                http.write_json({ error = "Failed to save data" })
                return
            end
            local log_text = os.date("%H:%M %d.%m.%Y") .. "|manual|updated=0|unchanged=1|failed=0"
                .. "\n  " .. section_name .. ":\n    " .. S.clean_log_field(proxy_name) .. ": unchanged"
            S.append_log(SRV.UPDATE_LOG_FILE, SRV.UPDATE_LOG_MAX, log_text)
            http.write_json({ success = true, unchanged = true })
            return
        end

        S.write_sub_backup()

        local ok2, err2 = S.replace_proxy_link(section_name, proxy_type, slot_index, new_link)
        if not ok2 then
            http.write_json({ error = err2 })
            return
        end

        local subs = S.read_subs(SRV.SUBS_FILE)
        if not subs[section_name] then subs[section_name] = {} end
        while #subs[section_name] < slot_index + 1 do
            table.insert(subs[section_name], false)
        end
        subs[section_name][slot_index + 1] = {
            subscription_url = subscription_url,
            proxy_name = proxy_name,
            last_updated = os.date("%H:%M %d.%m.%Y") .. " (manual)"
        }
        if not S.write_subs(subs, SRV.SUBS_FILE) then
            http.write_json({ error = "Failed to save data" })
            return
        end

        sys.exec("nohup /etc/init.d/podkop restart >/dev/null 2>&1 &")
        local log_text = os.date("%H:%M %d.%m.%Y") .. "|manual|updated=1|unchanged=0|failed=0"
            .. "\n  " .. section_name .. ":\n    " .. S.clean_log_field(proxy_name) .. ": updated"
        S.append_log(SRV.UPDATE_LOG_FILE, SRV.UPDATE_LOG_MAX, log_text)
        http.write_json({ success = true, restarting = true })
    end)

    if not ok then
        http.prepare_content("application/json")
        http.write_json({ error = "Internal error" })
    end
end

function M.subscription_detach()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()

    local ok, err = pcall(function()
        local section_name = http.formvalue("section") or ""
        local slot_index = tonumber(http.formvalue("index") or "-1")

        if not slot_index or slot_index < 0 or slot_index > 999 or section_name == "" then
            http.write_json({ error = "Missing required parameters" })
            return
        end
        if not LIB.sanitize_section_name(section_name) then
            http.write_json({ error = "Invalid section name" })
            return
        end

        local subs = S.read_subs(SRV.SUBS_FILE)
        if subs[section_name] and subs[section_name][slot_index + 1] then
            subs[section_name][slot_index + 1] = nil
            if not S.write_subs(subs, SRV.SUBS_FILE) then
                http.write_json({ error = "Failed to save data" })
                return
            end
        end

        http.write_json({ success = true })
    end)

    if not ok then
        http.prepare_content("application/json")
        http.write_json({ error = "Internal error" })
    end
end

function M.settings_read()
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()

    local subs = S.read_subs(SRV.SUBS_FILE)
    local settings = subs.settings or {}

    http.write_json({
        auto_update_interval = settings.auto_update_interval or 0,
        auto_update_start = settings.auto_update_start or "",
        auto_update_on_restart = settings.auto_update_on_restart or false,
        log_display_count = settings.log_display_count or 10
    })
end

function M.settings_save()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()

    local ok, err = pcall(function()
        local interval = tonumber(http.formvalue("auto_update_interval") or "0") or 0
        local start_time = http.formvalue("auto_update_start") or ""
        local on_restart = http.formvalue("auto_update_on_restart") == "1"
        local log_display = tonumber(http.formvalue("log_display_count") or "10") or 10
        if log_display < 1 then log_display = 1 end
        if log_display > 25 then log_display = 25 end

        if interval > 0 then
            if interval < 1 or interval > 24 then
                http.write_json({ error = "Interval must be 1-24 hours" })
                return
            end
            if not start_time:match("^%d%d:%d%d$") then
                http.write_json({ error = "Invalid start time, use HH:MM" })
                return
            end
            local sh = tonumber(start_time:sub(1, 2))
            local sm = tonumber(start_time:sub(4, 5))
            if not sh or sh > 23 or not sm or sm > 59 then
                http.write_json({ error = "Invalid start time value" })
                return
            end
        else
            interval = 0
            start_time = ""
        end

        local subs = S.read_subs(SRV.SUBS_FILE)
        subs.settings = {
            auto_update_interval = interval,
            auto_update_start = start_time,
            auto_update_on_restart = on_restart,
            log_display_count = log_display
        }
        if not S.write_subs(subs, SRV.SUBS_FILE) then
            http.write_json({ error = "Failed to save settings" })
            return
        end

        SCHED.create_auto_update_script()

        SCHED.setup_cron(interval, start_time)
        SCHED.setup_hotplug(on_restart)

        http.write_json({ success = true })
    end)

    if not ok then
        http.prepare_content("application/json")
        http.write_json({ error = "Internal error" })
    end
end

function M.update_all()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()

    local ok, err = pcall(function()
        local sys = require("luci.sys")
        local result = S.update_all_subscriptions(SRV.SUBS_FILE, SRV.UPDATE_LOG_FILE, SRV.UPDATE_LOG_MAX, "manual")

        if result.need_restart then
            sys.exec("nohup /etc/init.d/podkop restart >/dev/null 2>&1 &")
        end

        http.write_json({
            success = true,
            updated = result.updated,
            unchanged = result.unchanged,
            failed = result.failed,
            restarted = result.need_restart
        })
    end)

    if not ok then
        http.prepare_content("application/json")
        http.write_json({ error = "Internal error" })
    end
end

function M.download_sub_backup()
    local http = require("luci.http")
    local nixio = require("nixio")
    local backup_path = "/etc/config/podkop.sub-backup"
    if not nixio.fs.stat(backup_path) then
        http.prepare_content("application/json")
        http.write_json({ error = "Sub backup file not found" })
        return
    end
    http.prepare_content("application/octet-stream")
    http.header("Content-Disposition", 'attachment; filename="podkop-sub-backup.conf"')
    local fd = io.open(backup_path, "r")
    if fd then
        local content = fd:read("*a")
        fd:close()
        http.write(content)
    else
        http.status(500, "Cannot read sub backup")
    end
end

return M
