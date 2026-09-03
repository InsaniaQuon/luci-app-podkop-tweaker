-- Podkop Tweaker | v4.4.0 | 30.08.2026 | write flow via services.singbox_apply_checked (checked rename)
-- Hybrid exceptions kept as-is: read_config, export_config, download_backup (transport endpoints)

local H = require("podkop-tweaker.http")
local SRV = require("podkop-tweaker.services")

local M = {}

function M.read_config()
    H.send_text_file(SRV.SINGBOX_CONFIG)
end

function M.save_config(content)
    local sys = require("luci.sys")
    local ok, err = SRV.singbox_content_check(content, "Configuration is empty")
    if not ok then
        return { error = err }
    end
    local rfd = io.open(SRV.SINGBOX_CONFIG, "r")
    if rfd then
        local orig = rfd:read("*a")
        rfd:close()
        if orig == content then
            return { success = true, unchanged = true }
        end
    end
    local details
    ok, err, details = SRV.singbox_apply_checked(content, ".tmp-write", "sing-box check failed")
    if not ok then
        if details then
            return { error = err, details = details }
        end
        return { error = err }
    end
    sys.exec("/etc/init.d/sing-box restart 2>&1")
    return { success = true, restarting = true }
end

function M.service_status()
    return SRV.service_status(SRV.ops.singbox)
end

function M.service_toggle(action)
    return SRV.service_toggle(SRV.ops.singbox, action)
end

function M.rollback()
    return SRV.rollback(SRV.ops.singbox)
end

function M.export_config()
    H.send_download(SRV.SINGBOX_CONFIG, "singbox-config.json", "Not Found")
end

function M.download_backup()
    H.send_download(SRV.SINGBOX_BACKUP, "singbox-backup.json", "No sing-box backup found")
end

function M.import_config(content)
    local sys = require("luci.sys")
    local ok, err = SRV.singbox_content_check(content, "Empty content")
    if not ok then
        return { error = err }
    end
    local details
    ok, err, details = SRV.singbox_apply_checked(content, ".tmp-import", "sing-box check failed")
    if not ok then
        if details then
            return { error = err, details = details }
        end
        return { error = err }
    end
    sys.exec("/etc/init.d/sing-box restart 2>&1")
    return { success = true, restarting = true }
end

function M.outbounds()
    local sys = require("luci.sys")
    local raw = sys.exec("jq '.outbounds[] | {tag, type, server: (.server // \"\"), tls_enabled: (.tls.enabled // false), has_fragment: ((.tls.fragment // false) or (.tls.record_fragment // false))}' " .. SRV.SINGBOX_CONFIG .. " 2>/dev/null")
    if not raw or raw == "" then
        return { outbounds = {} }
    end
    local outbounds = {}
    local cur = {}
    for line in raw:gmatch("[^\r\n]+") do
        local tag = line:match('"tag":%s*"([^"]+)"')
        local typ = line:match('"type":%s*"([^"]+)"')
        local srv = line:match('"server":%s*"([^"]*)"')
        local tls_en = line:match('"tls_enabled":%s*(true)')
        local tls_dis = line:match('"tls_enabled":%s*(false)')
        local frag_en = line:match('"has_fragment":%s*(true)')
        local frag_dis = line:match('"has_fragment":%s*(false)')
        if tag then cur.tag = tag end
        if typ then cur.type = typ end
        if srv then cur.server = srv end
        if tls_en then cur.tls_enabled = true end
        if tls_dis then cur.tls_enabled = false end
        if frag_en then cur.has_fragment = true end
        if frag_dis then cur.has_fragment = false end
        if line:match("^%}") then
            table.insert(outbounds, cur)
            cur = {}
        end
    end
    return { outbounds = outbounds }
end

function M.patch_fragment(tags_raw, mode_raw, use_fragment_raw, use_record_fragment_raw, fallback_delay_raw)
    local sys = require("luci.sys")
    local json = require("luci.jsonc")

    local tags = json.parse(tags_raw or "[]")
    if not tags or type(tags) ~= "table" or #tags == 0 then
        return { error = "No outbounds selected" }
    end
    for i, t in ipairs(tags) do
        if type(t) ~= "string" or not t:match("^[a-zA-Z0-9_%-%.]+$") then
            return { error = "Invalid tag value" }
        end
    end
    local mode = mode_raw or "apply"
    local rfd = io.open(SRV.SINGBOX_CONFIG, "r")
    if not rfd then
        return { error = "Cannot read config" }
    end
    local orig = rfd:read("*a")
    rfd:close()
    local bfd = io.open(SRV.SINGBOX_BACKUP, "w")
    if bfd then
        bfd:write(orig)
        bfd:close()
    end
    local jq_args = ""
    local jq_select = ""
    for i, t in ipairs(tags) do
        jq_args = jq_args .. ' --arg t' .. i .. ' ' .. t
        if i > 1 then jq_select = jq_select .. " or " end
        jq_select = jq_select .. '.tag == $t' .. i
    end
    local jq_expr
    if mode == "remove" then
        jq_expr = '(.outbounds[] | select(' .. jq_select .. ') | .tls) |= del(.fragment, .record_fragment, .fragment_fallback_delay)'
    else
        local use_fragment = use_fragment_raw == "1"
        local use_record_fragment = use_record_fragment_raw == "1"
        if not use_fragment and not use_record_fragment then
            return { error = "Select at least one fragment method" }
        end
        local fallback_delay = fallback_delay_raw or "500ms"
        if not fallback_delay:match("^%d+%a+$") then
            return { error = "Invalid fallback_delay format" }
        end
        if use_fragment then
            local rf_val = use_record_fragment and "true" or "false"
            jq_expr = '(.outbounds[] | select(' .. jq_select .. ') | .tls) |= . + {"fragment": true, "record_fragment": (' .. rf_val .. '), "fragment_fallback_delay": "' .. fallback_delay .. '"}'
        else
            jq_expr = '(.outbounds[] | select(' .. jq_select .. ') | .tls) |= . + {"fragment": false, "record_fragment": true} | (.outbounds[] | select(' .. jq_select .. ') | .tls) |= del(.fragment_fallback_delay)'
        end
    end
    local patched = sys.exec("jq " .. jq_args .. " '" .. jq_expr .. "' " .. SRV.SINGBOX_CONFIG .. " 2>/dev/null")
    if not patched or patched == "" then
        return { error = "jq patch failed" }
    end
    local ok, err, details = SRV.singbox_apply_checked(patched, ".tmp-patch", "sing-box check failed after patch")
    if not ok then
        if details then
            return { error = err, details = details }
        end
        return { error = err }
    end
    sys.exec("/etc/init.d/sing-box restart 2>&1")
    return { success = true, restarting = true }
end

function M.wrapper_status()
    local fd = io.open("/etc/init.d/podkop.orig", "r")
    local installed = (fd ~= nil)
    if fd then fd:close() end
    local stale = false
    if installed then
        local ifd = io.open("/etc/init.d/podkop", "r")
        if ifd then
            local content = ifd:read("*a")
            ifd:close()
            if not content:find("podkop-fragment-patch.sh", 1, true) then
                stale = true
            end
        end
    end
    return {
        installed = installed,
        stale = stale
    }
end

function M.wrapper_toggle(action, fragment_raw, record_fragment_raw, fallback_delay_raw)
    local sys = require("luci.sys")

    if action ~= "enable" and action ~= "disable" and action ~= "reinstall" then
        return { error = "Invalid action" }
    end
    if action == "reinstall" then
        os.remove("/etc/init.d/podkop.orig")
    elseif action == "enable" then
        local uci = require("luci.model.uci").cursor()
        local fragment = fragment_raw == "1"
        local record_fragment = record_fragment_raw == "1"
        local fallback_delay = fallback_delay_raw or "500ms"
        if not fallback_delay:match("^%d+%a+$") then
            fallback_delay = "500ms"
        end
        uci:set("podkop-fragment", "settings", "fragment", fragment and "true" or "false")
        uci:set("podkop-fragment", "settings", "record_fragment", record_fragment and "true" or "false")
        uci:set("podkop-fragment", "settings", "fragment_fallback_delay", fallback_delay)
        uci:commit("podkop-fragment")
    end
    if action == "reinstall" then action = "enable" end
    local output = sys.exec("/etc/init.d/podkop-fragment " .. action .. " 2>&1; echo EXIT:$?")
    local exit_code = output:match("EXIT:(%d+)") or "1"
    if exit_code ~= "0" then
        local err_msg = output:gsub("EXIT:%d+%s*$", ""):match("^%s*(.-)%s*$") or "Command failed"
        return { success = false, error = err_msg }
    end
    local fd = io.open("/etc/init.d/podkop.orig", "r")
    local resp = {
        success = true,
        installed = (fd ~= nil)
    }
    if fd then fd:close() end
    return resp
end

function M.fragment_settings()
    local uci = require("luci.model.uci").cursor()
    local fragment = uci:get("podkop-fragment", "settings", "fragment") or "false"
    local record_fragment = uci:get("podkop-fragment", "settings", "record_fragment") or "true"
    local fallback_delay = uci:get("podkop-fragment", "settings", "fragment_fallback_delay") or "500ms"
    return {
        fragment = (fragment == "true"),
        record_fragment = (record_fragment == "true"),
        fallback_delay = fallback_delay
    }
end

return M
