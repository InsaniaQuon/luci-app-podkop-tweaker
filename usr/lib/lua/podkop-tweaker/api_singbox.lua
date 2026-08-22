-- Podkop Tweaker | Sing-box config + fragment wrapper API handlers
-- Author: InsaniaQuon

local H = require("podkop-tweaker.http")
local SRV = require("podkop-tweaker.services")

local M = {}

function M.read_config()
    local http = require("luci.http")
    http.prepare_content("text/plain")
    H.no_cache()
    local fd = io.open(SRV.SINGBOX_CONFIG, "r")
    if fd then
        local content = fd:read("*a")
        fd:close()
        http.write(content)
    else
        http.write("")
    end
end

function M.save_config()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    H.no_cache()
    local content = http.formvalue("content") or ""
    local ok, err = SRV.singbox_content_check(content, "Configuration is empty")
    if not ok then
        http.write_json({ error = err })
        return
    end
    local rfd = io.open(SRV.SINGBOX_CONFIG, "r")
    if rfd then
        local orig = rfd:read("*a")
        rfd:close()
        if orig == content then
            http.write_json({ success = true, unchanged = true })
            return
        end
        local bfd = io.open(SRV.SINGBOX_BACKUP, "w")
        if bfd then
            bfd:write(orig)
            bfd:close()
        end
    end
    local tmp_path = SRV.SINGBOX_CONFIG .. ".tmp-write"
    local tmpfd = io.open(tmp_path, "w")
    if not tmpfd then
        http.write_json({ error = "Cannot write temporary file" })
        return
    end
    tmpfd:write(content)
    tmpfd:close()
    local check = sys.exec("sing-box check -c " .. tmp_path .. " 2>&1")
    if check and check ~= "" then
        os.remove(tmp_path)
        http.write_json({ error = "sing-box check failed", details = check })
        return
    end
    os.rename(tmp_path, SRV.SINGBOX_CONFIG)
    sys.exec("/etc/init.d/sing-box restart 2>&1")
    http.write_json({ success = true, restarting = true })
end

function M.service_status()
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()
    local pid = H.get_service_pid("sing-box")
    http.write_json({
        running = (pid ~= nil),
        pid = pid
    })
end

function M.service_toggle()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    H.no_cache()
    local action = http.formvalue("action") or ""
    if action ~= "start" and action ~= "stop" then
        http.write_json({ error = "Invalid action" })
        return
    end
    sys.exec("/etc/init.d/sing-box " .. action .. " 2>&1")
    local pid = H.get_service_pid("sing-box")
    http.write_json({
        success = true,
        running = (pid ~= nil)
    })
end

function M.rollback()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    H.no_cache()
    local ok, err = SRV.restore_backup(SRV.singbox)
    if not ok then
        http.write_json({ error = (err == "not_found") and "Backup file not found" or "Cannot write config" })
        return
    end
    sys.exec(SRV.singbox.restart_cmd)
    http.write_json({ success = true, restarting = true })
end

function M.export_config()
    local http = require("luci.http")
    http.prepare_content("application/octet-stream")
    H.no_cache()
    http.header("Content-Disposition", 'attachment; filename="singbox-config.json"')
    local fd = io.open(SRV.SINGBOX_CONFIG, "r")
    if fd then
        local content = fd:read("*a")
        fd:close()
        http.write(content)
    else
        http.status(404, "Not Found")
        http.write("")
    end
end

function M.download_backup()
    local http = require("luci.http")
    http.prepare_content("application/octet-stream")
    H.no_cache()
    if not io.open(SRV.SINGBOX_BACKUP, "r") then
        http.status(404, "Not Found")
        http.write_json({ error = "No sing-box backup found" })
        return
    end
    http.header("Content-Disposition", 'attachment; filename="singbox-backup.json"')
    local fd = io.open(SRV.SINGBOX_BACKUP, "r")
    if fd then
        local data = fd:read("*a")
        fd:close()
        http.write(data)
    else
        http.write("")
    end
end

function M.import_config()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    H.no_cache()
    local content = http.formvalue("content") or ""
    local ok, err = SRV.singbox_content_check(content, "Empty content")
    if not ok then
        http.write_json({ error = err })
        return
    end
    local tmp_path = SRV.SINGBOX_CONFIG .. ".tmp-import"
    local tmpfd = io.open(tmp_path, "w")
    if not tmpfd then
        http.write_json({ error = "Cannot write temporary file" })
        return
    end
    tmpfd:write(content)
    tmpfd:close()
    local check = sys.exec("sing-box check -c " .. tmp_path .. " 2>&1")
    if check and check ~= "" then
        os.remove(tmp_path)
        http.write_json({ error = "sing-box check failed", details = check })
        return
    end
    local rfd = io.open(SRV.SINGBOX_CONFIG, "r")
    if rfd then
        local orig = rfd:read("*a")
        rfd:close()
        local bfd = io.open(SRV.SINGBOX_BACKUP, "w")
        if bfd then
            bfd:write(orig)
            bfd:close()
        end
    end
    os.rename(tmp_path, SRV.SINGBOX_CONFIG)
    sys.exec("/etc/init.d/sing-box restart 2>&1")
    http.write_json({ success = true, restarting = true })
end

function M.outbounds()
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    H.no_cache()
    local raw = sys.exec("jq '.outbounds[] | {tag, type, server: (.server // \"\"), tls_enabled: (.tls.enabled // false), has_fragment: ((.tls.fragment // false) or (.tls.record_fragment // false))}' " .. SRV.SINGBOX_CONFIG .. " 2>/dev/null")
    if not raw or raw == "" then
        http.write_json({ outbounds = {} })
        return
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
    http.write_json({ outbounds = outbounds })
end

function M.patch_fragment()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    H.no_cache()
    local json = require("luci.jsonc")
    local tags_raw = http.formvalue("tags") or "[]"
    local tags = json.parse(tags_raw)
    if not tags or type(tags) ~= "table" or #tags == 0 then
        http.write_json({ error = "No outbounds selected" })
        return
    end
    for i, t in ipairs(tags) do
        if type(t) ~= "string" or not t:match("^[a-zA-Z0-9_%-%.]+$") then
            http.write_json({ error = "Invalid tag value" })
            return
        end
    end
    local mode = http.formvalue("mode") or "apply"
    local rfd = io.open(SRV.SINGBOX_CONFIG, "r")
    if not rfd then
        http.write_json({ error = "Cannot read config" })
        return
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
        local use_fragment = http.formvalue("fragment") == "1"
        local use_record_fragment = http.formvalue("record_fragment") == "1"
        if not use_fragment and not use_record_fragment then
            http.write_json({ error = "Select at least one fragment method" })
            return
        end
        local fallback_delay = http.formvalue("fallback_delay") or "500ms"
        if not fallback_delay:match("^%d+%a+$") then
            http.write_json({ error = "Invalid fallback_delay format" })
            return
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
        http.write_json({ error = "jq patch failed" })
        return
    end
    local tmp_path = SRV.SINGBOX_CONFIG .. ".tmp-patch"
    local tmpfd = io.open(tmp_path, "w")
    if not tmpfd then
        http.write_json({ error = "Cannot write temporary file" })
        return
    end
    tmpfd:write(patched)
    tmpfd:close()
    local check = sys.exec("sing-box check -c " .. tmp_path .. " 2>&1")
    if check and check ~= "" then
        os.remove(tmp_path)
        http.write_json({ error = "sing-box check failed after patch", details = check })
        return
    end
    os.rename(tmp_path, SRV.SINGBOX_CONFIG)
    sys.exec("/etc/init.d/sing-box restart 2>&1")
    http.write_json({ success = true, restarting = true })
end

function M.wrapper_status()
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()
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
    http.write_json({
        installed = installed,
        stale = stale
    })
end

function M.wrapper_toggle()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    H.no_cache()
    local action = http.formvalue("action") or ""
    if action ~= "enable" and action ~= "disable" and action ~= "reinstall" then
        http.write_json({ error = "Invalid action" })
        return
    end
    if action == "reinstall" then
        os.remove("/etc/init.d/podkop.orig")
    elseif action == "enable" then
        local uci = require("luci.model.uci").cursor()
        local fragment = http.formvalue("fragment") == "1"
        local record_fragment = http.formvalue("record_fragment") == "1"
        local fallback_delay = http.formvalue("fallback_delay") or "500ms"
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
        http.write_json({ success = false, error = err_msg })
        return
    end
    local fd = io.open("/etc/init.d/podkop.orig", "r")
    http.write_json({
        success = true,
        installed = (fd ~= nil)
    })
    if fd then fd:close() end
end

function M.fragment_settings()
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()
    local uci = require("luci.model.uci").cursor()
    local fragment = uci:get("podkop-fragment", "settings", "fragment") or "false"
    local record_fragment = uci:get("podkop-fragment", "settings", "record_fragment") or "true"
    local fallback_delay = uci:get("podkop-fragment", "settings", "fragment_fallback_delay") or "500ms"
    http.write_json({
        fragment = (fragment == "true"),
        record_fragment = (record_fragment == "true"),
        fallback_delay = fallback_delay
    })
end

return M
