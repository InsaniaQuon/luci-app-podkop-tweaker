local M = {}

local SUBS_VERSION = 1

local _json_ok, _json = pcall(require, "luci.jsonc")
if not _json_ok then
    error("pt-subs-lib requires luci.jsonc")
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64lut = {}
for i = 1, #B64 do b64lut[B64:sub(i, i)] = i - 1 end
b64lut["="] = 0

function M.b64decode(s)
    s = s:gsub("%s+", "")
    local out = {}
    for i = 1, #s, 4 do
        local a, b, c, d = b64lut[s:sub(i, i)], b64lut[s:sub(i+1, i+1)], b64lut[s:sub(i+2, i+2)], b64lut[s:sub(i+3, i+3)]
        if not a or not b then break end
        local v = a * 262144 + b * 4096 + (c or 0) * 64 + (d or 0)
        table.insert(out, string.char(math.floor(v / 65536) % 256))
        if s:sub(i+2, i+2) ~= "=" then
            table.insert(out, string.char(math.floor(v / 256) % 256))
        end
        if s:sub(i+3, i+3) ~= "=" then
            table.insert(out, string.char(v % 256))
        end
    end
    return table.concat(out)
end

function M.url_decode(s)
    if not s then return "" end
    s = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    s = s:gsub("%+", " ")
    return s
end

function M.parse_proxy_link(link)
    if not link or link == "" then return nil end
    local name = ""
    local hash_pos = link:find("#", 1, true)
    local base_link = link
    if hash_pos then
        name = M.url_decode(link:sub(hash_pos + 1))
        base_link = link:sub(1, hash_pos - 1)
    end
    local proto = base_link:match("^(%w+)://") or "unknown"
    local after_at = base_link:match("@([^%?]+)")
    local server, port
    if after_at then
        port = after_at:match(":(%d+)$")
        if port then
            server = after_at:sub(1, #after_at - #port - 1)
        else
            server = after_at
        end
        if server and server:match("^%[.+%]$") then
            server = server:sub(2, #server - 1)
        end
    end
    local security = ""
    local query = base_link:match("%?(.+)$")
    if query then
        security = query:match("security=([^&]+)") or ""
    end
    return {
        name = name ~= "" and name or (server or "unknown"),
        protocol = proto:upper(),
        server = server or "unknown",
        port = port or "",
        security = security ~= "" and security or "none",
        link = link
    }
end

function M.shell_escape(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function M.parse_subscription_raw(raw)
    local content = raw
    if not raw:match("vless://") and not raw:match("vmess://")
        and not raw:match("ss://") and not raw:match("trojan://") then
        local decoded = M.b64decode(raw)
        if decoded and type(decoded) == "string"
            and (decoded:match("vless://") or decoded:match("vmess://")
                or decoded:match("ss://") or decoded:match("trojan://")) then
            content = decoded
        end
    end
    local proxies = {}
    for line in content:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line:match("^vless://") or line:match("^vmess://")
            or line:match("^ss://") or line:match("^trojan://") then
            local p = M.parse_proxy_link(line)
            if p then table.insert(proxies, p) end
        end
    end
    return proxies
end

function M.json_parse(str)
    if not str or str == "" then return nil end
    local ok, result = pcall(_json.parse, str)
    if ok and result then return result end
    return nil
end

function M.json_stringify(data)
    local ok, result = pcall(_json.stringify, data)
    if ok then return result end
    return nil
end

function M.read_subs(subs_file)
    local fd = io.open(subs_file, "r")
    if not fd then return {} end
    local data = fd:read("*a")
    fd:close()
    local subs = M.json_parse(data)
    if type(subs) ~= "table" then subs = {} end
    subs.version = nil
    return subs
end

function M.write_subs(subs, subs_file)
    subs.version = SUBS_VERSION
    local str = M.json_stringify(subs)
    subs.version = nil
    if not str then return false end
    local tmp = subs_file .. ".tmp"
    local fd = io.open(tmp, "w")
    if not fd then return false end
    fd:write(str)
    fd:close()
    os.rename(tmp, subs_file)
    return true
end

function M.get_proxy_sections()
    local uci = require("luci.model.uci").cursor()
    local result = {}
    uci:foreach("podkop", "section", function(s)
        if s[".name"] and s.connection_type == "proxy" and s.proxy_config_type then
            local pct = s.proxy_config_type
            local links = {}
            if pct == "url" then
                local url = uci:get("podkop", s[".name"], "proxy_string")
                if url and url ~= "" then links = {url} end
            elseif pct == "urltest" then
                local l = uci:get("podkop", s[".name"], "urltest_proxy_links")
                if type(l) == "table" then links = l
                elseif type(l) == "string" and l ~= "" then links = {l} end
            elseif pct == "selector" then
                local l = uci:get("podkop", s[".name"], "selector_proxy_links")
                if type(l) == "table" then links = l
                elseif type(l) == "string" and l ~= "" then links = {l} end
            end
            if #links > 0 then
                table.insert(result, {
                    name = s[".name"],
                    proxy_config_type = pct,
                    proxy_links = links
                })
            end
        end
    end)
    return result
end

function M.replace_proxy_link(section_name, proxy_type, slot_index, new_link)
    local config_path = "/etc/config/podkop"
    local fd = io.open(config_path, "r")
    if not fd then return false, "Cannot read config" end
    local lines = {}
    for line in fd:lines() do
        table.insert(lines, line)
    end
    fd:close()

    local safe_link = new_link:gsub("'", "'\\''")

    local list_name
    if proxy_type == "url" then list_name = "url"
    elseif proxy_type == "urltest" then list_name = "urltest_proxy_links"
    elseif proxy_type == "selector" then list_name = "selector_proxy_links"
    else return false, "Unknown proxy type" end

    local in_section = false
    local is_option = (proxy_type == "url")
    local count = 0
    local found = false

    for i, line in ipairs(lines) do
        local sn = line:match("^%s*config%s+section%s+'([^']+)'")
        if not sn then sn = line:match("^%s*config%s+section%s+\"([^\"]+)\"") end
        if not sn then sn = line:match("^%s*config%s+section%s+(%S+)") end
        if sn then
            in_section = (sn == section_name)
        end
        if in_section and not found then
            if is_option then
                if line:match("^%s*option%s+proxy_string%s+") then
                    lines[i] = "\toption proxy_string '" .. safe_link .. "'"
                    found = true
                end
            else
                if line:match("^%s*list%s+" .. list_name .. "%s+") then
                    if count == slot_index then
                        lines[i] = "\tlist " .. list_name .. " '" .. safe_link .. "'"
                        found = true
                    end
                    count = count + 1
                end
            end
        end
    end

    if not found then
        return false, "Proxy link not found in config"
    end

    local tmp_path = config_path .. ".tmp"
    local wfd = io.open(tmp_path, "w")
    if not wfd then return false, "Cannot write config" end
    for _, line in ipairs(lines) do
        wfd:write(line .. "\n")
    end
    wfd:close()
    os.rename(tmp_path, config_path)
    return true
end

function M.backup_file(src, dst)
    local rfd = io.open(src, "r")
    if not rfd then return false end
    local data = rfd:read("*a")
    rfd:close()
    if not data then return false end
    local tmp = dst .. ".tmp"
    local fd = io.open(tmp, "w")
    if not fd then return false end
    fd:write(data)
    fd:close()
    os.rename(tmp, dst)
    return true
end

function M.backup_config()
    return M.backup_file("/etc/config/podkop", "/etc/config/podkop.auto-backup")
end

function M.backup_stubby_config()
    return M.backup_file("/etc/config/stubby", "/etc/config/stubby.auto-backup")
end

function M.do_update_subscription(section_name, slot_index, sub_url, proxy_name)
    if not section_name or not section_name:match("^[a-zA-Z0-9_%-]+$") then
        return nil, "invalid section name"
    end
    if not sub_url or not sub_url:match("^https?://") then
        return nil, "invalid url"
    end
    local safe_url = M.shell_escape(sub_url)

    local raw = nil
    local max_retries = 3
    local last_err = "download failed"
    local success_attempt = 0
    for attempt = 1, max_retries do
        local tmp = (io.popen("mktemp /tmp/pt-sub-XXXXXX 2>/dev/null"):read("*l"))
            or "/tmp/pt-sub-" .. os.time() .. "-" .. section_name
        os.execute("curl -sL -m 15 -A 'sing-box' -o " .. tmp .. " " .. safe_url .. " 2>/dev/null")

        local fd = io.open(tmp, "r")
        if fd then
            local data = fd:read("*a")
            fd:close()
            os.remove(tmp)
            if data and #data > 0 then
                local proxies = M.parse_subscription_raw(data)
                if #proxies > 0 then
                    raw = data
                    success_attempt = attempt
                    break
                end
                last_err = "no proxies found"
            else
                last_err = "empty response"
            end
        else
            last_err = "download failed"
        end

        if attempt < max_retries then
            os.execute("sleep 10 2>/dev/null")
        end
    end

    if not raw then
        return nil, last_err .. " (" .. max_retries .. " retries)"
    end

    local proxies = M.parse_subscription_raw(raw)

    local found = nil
    if proxy_name and proxy_name ~= "" then
        for _, p in ipairs(proxies) do
            if p.name == proxy_name then found = p; break end
        end
    end
    if not found and #proxies == 1 then found = proxies[1] end
    if not found then return nil, "proxy not found" end

    return found, nil, success_attempt
end

function M.update_subs_timestamp(subs_file, section_name, slot_index, mode)
    local subs = M.read_subs(subs_file)
    if not subs[section_name] then subs[section_name] = {} end
    local existing = subs[section_name][slot_index + 1]
    if not existing or type(existing) ~= "table" or not existing.subscription_url then
        return false
    end
    subs[section_name][slot_index + 1] = {
        subscription_url = existing.subscription_url,
        proxy_name = existing.proxy_name or "",
        last_updated = os.date("%H:%M %d.%m.%Y") .. " (" .. mode .. ")"
    }
    M.write_subs(subs, subs_file)
    return true
end

function M.rotate_log(log_file, max_events)
    local fd = io.open(log_file, "r")
    if not fd then return end
    local all_lines = {}
    for line in fd:lines() do
        all_lines[#all_lines + 1] = line
    end
    fd:close()

    local event_count = 0
    for i = #all_lines, 1, -1 do
        if not all_lines[i]:match("^%s") then
            event_count = event_count + 1
            if event_count == max_events then
                local wfd = io.open(log_file, "w")
                if not wfd then return end
                for j = i, #all_lines do
                    wfd:write(all_lines[j] .. "\n")
                end
                wfd:close()
                return
            end
        end
    end
end

function M.append_log(log_file, max_events, text)
    M.rotate_log(log_file, max_events - 1)
    local fd = io.open(log_file, "a")
    if not fd then return end
    fd:write(text .. "\n")
    fd:close()
end

function M.write_sub_backup()
    return M.backup_file("/etc/config/podkop", "/etc/config/podkop.sub-backup")
end

function M.update_all_subscriptions(subs_file, log_file, log_max, mode)
    local sections = M.get_proxy_sections()
    local subs = M.read_subs(subs_file)
    local updated, unchanged, failed = 0, 0, 0
    local need_restart = false
    local need_backup = true
    local details = {}

    for _, sec in ipairs(sections) do
        local sec_subs = subs[sec.name] or {}
        for i, link in ipairs(sec.proxy_links) do
            local sub_entry = sec_subs[i]
            if sub_entry and type(sub_entry) == "table"
                and sub_entry.subscription_url and sub_entry.subscription_url ~= "" then
                local proxy, err, attempt = M.do_update_subscription(
                    sec.name, i - 1, sub_entry.subscription_url, sub_entry.proxy_name)
                local pname = sub_entry.proxy_name or ""
                local retry_suffix = (attempt and attempt > 1) and (" (retry " .. attempt .. ")") or ""
                if proxy and proxy.link then
                    local current_link = link or ""
                    if current_link ~= proxy.link then
                        if need_backup then
                            M.write_sub_backup()
                            need_backup = false
                        end
                        local rok, _ = M.replace_proxy_link(sec.name, sec.proxy_config_type, i - 1, proxy.link)
                        if rok then
                            updated = updated + 1
                            need_restart = true
                            table.insert(details, {section = sec.name, slot = i - 1, proxy = pname, status = "updated" .. retry_suffix})
                        else
                            failed = failed + 1
                            table.insert(details, {section = sec.name, slot = i - 1, proxy = pname, status = "failed"})
                        end
                    else
                        unchanged = unchanged + 1
                        table.insert(details, {section = sec.name, slot = i - 1, proxy = pname, status = "unchanged" .. retry_suffix})
                    end
                    M.update_subs_timestamp(subs_file, sec.name, i - 1, mode)
                else
                    failed = failed + 1
                    local label = "failed"
                    if err and err:match("retries") then label = "failed (" .. err .. ")" end
                    table.insert(details, {section = sec.name, slot = i - 1, proxy = pname, status = label})
                end
            end
        end
    end

    local log_text = os.date("%H:%M %d.%m.%Y") .. "|" .. mode .. "|updated=" .. updated
        .. "|unchanged=" .. unchanged .. "|failed=" .. failed
    local by_section = {}
    for _, d in ipairs(details) do
        if not by_section[d.section] then by_section[d.section] = {} end
        by_section[d.section][#by_section[d.section] + 1] = d
    end
    local sec_names = {}
    for k, _ in pairs(by_section) do sec_names[#sec_names + 1] = k end
    table.sort(sec_names)
    for _, sname in ipairs(sec_names) do
        log_text = log_text .. "\n  " .. sname .. ":"
        for _, d in ipairs(by_section[sname]) do
            log_text = log_text .. "\n    " .. d.proxy .. ": " .. d.status
        end
    end
    M.append_log(log_file, log_max, log_text)

    return {
        updated = updated,
        unchanged = unchanged,
        failed = failed,
        need_restart = need_restart,
        details = details
    }
end

function M.apply_files_from_dir(extract_dir, relaxed)
    local sys = require("luci.sys")
    local find_cmd = "find '" .. extract_dir .. "' -type f \\! -type l 2>/dev/null"
    local raw = sys.exec(find_cmd)
    local prefix_len = #extract_dir + 1
    local copied = 0

    for line in raw:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then
            local rel = line:sub(prefix_len):match("^/?(.*)")
            if rel ~= "" and M._is_valid_update_path(rel, relaxed) then
                local dest = "/" .. rel
                local dest_dir = dest:match("^(.+)/[^/]+$")
                if dest_dir then
                    sys.exec("mkdir -p '" .. dest_dir .. "' 2>/dev/null")
                end
                local src_fd = io.open(line, "rb")
                if src_fd then
                    local data = src_fd:read("*a")
                    src_fd:close()
                    local dst_fd = io.open(dest, "wb")
                    if dst_fd then
                        dst_fd:write(data)
                        dst_fd:close()
                        copied = copied + 1
                    end
                end
            end
        end
    end

    return copied
end

function M._is_valid_update_path(rel_path, relaxed)
    if rel_path:find("..", 1, true) then return false end
    if relaxed then
        if rel_path:match("^usr/lib/lua/") then return true end
        if rel_path:match("^usr/share/luci/") then return true end
        if rel_path:match("^usr/share/rpcd/") then return true end
        return false
    end
    if rel_path:match("^usr/lib/lua/.*%.lua$") then return true end
    if rel_path:match("^usr/lib/lua/luci/view/podkop%-tweaker/[%w_%-]+%.htm$") then return true end
    if rel_path:match("^usr/share/luci/menu%.d/[%w_%-]+%.json$") then return true end
    if rel_path:match("^usr/share/rpcd/acl%.d/[%w_%-]+%.json$") then return true end
    return false
end

return M
