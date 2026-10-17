local M = {}
local LIB = require("podkop-tweaker.lib")
local SRV = require("podkop-tweaker.services")
local NET = require("podkop-tweaker.net")
local ARCHIVE = require("podkop-tweaker.archive")

M.SUB_MAX_SIZE = 1048576
M.SUB_MAX_PROXIES = 1000
M.LINK_MAX_SIZE = 16384

local SUBS_VERSION = 1

local _json_ok, _json = pcall(require, "luci.jsonc")
if not _json_ok then
    error("pt-subs-lib requires luci.jsonc")
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64lut = {}
for i = 1, #B64 do b64lut[B64:sub(i, i)] = i - 1 end
b64lut["="] = 0

function M.b64decode(s, limit)
    if type(s) ~= "string" then return nil, "Base64 input must be text" end
    limit = limit or M.SUB_MAX_SIZE
    if #s > limit * 2 + 64 then return nil, "Encoded content exceeds size limit" end
    s = s:gsub("%s+", "")
    local out, block, size = {}, {}, 0
    for i = 1, #s, 4 do
        local a, b, c, d = b64lut[s:sub(i, i)], b64lut[s:sub(i+1, i+1)], b64lut[s:sub(i+2, i+2)], b64lut[s:sub(i+3, i+3)]
        if not a or not b then break end
        local v = a * 262144 + b * 4096 + (c or 0) * 64 + (d or 0)
        local bytes = string.char(math.floor(v / 65536) % 256)
        if s:sub(i+2, i+2) ~= "=" then
            bytes = bytes .. string.char(math.floor(v / 256) % 256)
        end
        if s:sub(i+3, i+3) ~= "=" then
            bytes = bytes .. string.char(v % 256)
        end
        size = size + #bytes
        if size > limit then return nil, "Decoded content exceeds size limit" end
        block[#block + 1] = bytes
        if #block >= 1024 then out[#out + 1], block = table.concat(block), {} end
    end
    if #block > 0 then out[#out + 1] = table.concat(block) end
    return table.concat(out)
end

function M.url_decode(s)
    if not s then return "" end
    s = s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    s = s:gsub("%+", " ")
    return s
end

function M.parse_proxy_link(link)
    if type(link) ~= "string" or link == "" or #link > M.LINK_MAX_SIZE or link:find("%c") then return nil end
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
        name = name ~= "" and name:sub(1, 1024) or (server or "unknown"),
        protocol = proto:upper(),
        server = server or "unknown",
        port = port or "",
        security = security ~= "" and security or "none",
        link = link
    }
end

M.shell_escape = LIB.shell_escape

function M.clean_log_field(s)
    if s == nil then return "" end
    return (tostring(s):gsub("%c", " "))
end

function M.parse_subscription_raw(raw)
    if type(raw) ~= "string" then return {}, "Subscription content must be text" end
    if #raw > M.SUB_MAX_SIZE then return {}, "Subscription exceeds size limit" end
    if raw:find("[%z\1-\8\11\12\14-\31\127]") then return {}, "Subscription contains invalid control bytes" end
    local content = raw
    if not raw:match("vless://") and not raw:match("vmess://")
        and not raw:match("ss://") and not raw:match("trojan://") then
        local decoded, decode_err = M.b64decode(raw, M.SUB_MAX_SIZE)
        if not decoded then return {}, decode_err end
        if decoded and type(decoded) == "string"
            and (decoded:match("vless://") or decoded:match("vmess://")
                or decoded:match("ss://") or decoded:match("trojan://")) then
            content = decoded
        end
    end
    if content:find("[%z\1-\8\11\12\14-\31\127]") then return {}, "Subscription contains invalid control bytes" end
    local proxies = {}
    for line in content:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line:match("^vless://") or line:match("^vmess://")
            or line:match("^ss://") or line:match("^trojan://") then
            local p = M.parse_proxy_link(line)
            if not p then return {}, "Invalid or oversized proxy link" end
            table.insert(proxies, p)
            if #proxies > M.SUB_MAX_PROXIES then return {}, "Too many proxy links" end
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

function M.slot_count(slots)
    local max_n = 0
    for k in pairs(slots) do
        if type(k) == "number" then
            if k < 1 or k > M.SUB_MAX_PROXIES or k ~= math.floor(k) then
                return nil, "Invalid subscription slot index"
            end
            if k > max_n then max_n = k end
        end
    end
    return max_n
end

local function validate_slots(slots)
    local max_n, err = M.slot_count(slots)
    if not max_n then return false, err end
    for i = 1, max_n do
        local entry = slots[i]
        if entry ~= nil and entry ~= false then
            if type(entry) ~= "table" then return false, "Invalid subscription slot data" end
            if entry.subscription_url ~= nil and (type(entry.subscription_url) ~= "string" or
                entry.subscription_url ~= "" and not NET.valid_url(entry.subscription_url)) then
                return false, "Invalid stored subscription URL"
            end
            if entry.proxy_name ~= nil and (type(entry.proxy_name) ~= "string" or #entry.proxy_name > 1024) then
                return false, "Invalid stored proxy name"
            end
            if entry.last_updated ~= nil and type(entry.last_updated) ~= "string" then
                return false, "Invalid subscription timestamp"
            end
        end
    end
    return true
end

function M.subscription_slots(subs, section_name)
    local slots = subs[section_name]
    if slots == nil then return {} end
    if type(slots) ~= "table" then return nil, "Invalid subscriptions for section: " .. section_name end
    local ok, err = validate_slots(slots)
    if not ok then return nil, err .. " (" .. section_name .. ")" end
    return slots
end

local function validate_subs(subs)
    if type(subs) ~= "table" then return false, "Subscriptions state must be a JSON object" end
    if subs.version ~= nil and (type(subs.version) ~= "number" or subs.version < 1 or
        subs.version ~= math.floor(subs.version)) then return false, "Invalid subscriptions version" end
    if subs.settings ~= nil then
        local settings = subs.settings
        if type(settings) ~= "table" then return false, "Invalid subscriptions settings" end
        local interval, count = settings.auto_update_interval, settings.log_display_count
        if interval ~= nil and (type(interval) ~= "number" or interval < 0 or interval > 24 or
            interval ~= math.floor(interval)) then return false, "Invalid stored update interval" end
        if settings.auto_update_start ~= nil and type(settings.auto_update_start) ~= "string" then
            return false, "Invalid stored update start time"
        end
        if settings.auto_update_on_restart ~= nil and type(settings.auto_update_on_restart) ~= "boolean" then
            return false, "Invalid stored restart setting"
        end
        if count ~= nil and (type(count) ~= "number" or count < 1 or count > 25 or
            count ~= math.floor(count)) then return false, "Invalid stored log display count" end
    end
    for key, value in pairs(subs) do
        if type(key) ~= "string" then return false, "Subscriptions state must be a JSON object" end
        -- Retain extension metadata without guessing which unknown top-level
        -- keys name sections. Consumers use subscription_slots for active names.
        if key ~= "version" and key ~= "settings" and type(value) == "table" then
            local ok, err = validate_slots(value)
            if not ok then return false, err .. " (" .. key .. ")" end
        end
    end
    return true
end

function M.read_subs(subs_file)
    local data, err, errno = SRV.read_file(subs_file, M.SUB_MAX_SIZE)
    if not data then
        if errno == 2 then return {} end
        return nil, "Cannot read subscriptions: " .. tostring(err or "unknown IO error")
    end
    if not data:match("%S") then return nil, "Subscriptions state is empty" end
    if not data:match("^%s*{") then return nil, "Subscriptions state must be a JSON object" end
    local subs = M.json_parse(data)
    if not subs then return nil, "Invalid subscriptions JSON" end
    local ok, type_err = validate_subs(subs)
    if not ok then return nil, type_err end
    return subs
end

local function subs_bytes(subs)
    local ok, err = validate_subs(subs)
    if not ok then return nil, err end
    local copy = {}
    for key, value in pairs(subs) do
        copy[key] = value
        if key ~= "settings" and type(value) == "table" then
            local max_n = M.slot_count(value)
            if max_n > 0 then
                local slots = {}
                for field, item in pairs(value) do slots[field] = item end
                for i = 1, max_n do if slots[i] == nil then slots[i] = false end end
                copy[key] = slots
            end
        end
    end
    if copy.version == nil then copy.version = SUBS_VERSION end
    local str = M.json_stringify(copy)
    if type(str) ~= "string" or not str:match("^%s*{") then return nil, "Cannot encode subscriptions" end
    if #str > M.SUB_MAX_SIZE then return nil, "Subscriptions state exceeds size limit" end
    return str
end

-- Prepare state before publishing a related config change. The caller owns the
-- short subscriptions lock until it publishes/discards this services-owned stage.
function M.stage_subs(subs, subs_file)
    local str, err = subs_bytes(subs)
    if not str then return nil, err end
    return SRV.stage_file(subs_file, str, { suffix = ".tmp" })
end

-- The lock's third return is release uncertainty, not proof of publication.
-- These bool adapters expose only the callback's observed publication as their
-- third result; a separate fourth result carries any release uncertainty.
local function locked_publication(key, fn)
    local operation_err, applied, operation_unknown
    local ok, err, uncertain = SRV.with_lock(key, function()
        local written
        written, operation_err, applied, operation_unknown = fn()
        return written, operation_err
    end)
    if ok == nil and operation_err then err = tostring(operation_err) .. "\n" .. tostring(err) end
    return ok == true, err, applied == true or nil, uncertain or operation_unknown or nil
end

function M.write_subs(subs, subs_file)
    return locked_publication("subscriptions", function()
        local str, encode_err = subs_bytes(subs)
        if not str then return false, encode_err end
        local written, write_err = SRV.write_file_atomic(subs_file, str, { suffix = ".tmp" })
        return written, write_err, written
    end)
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
            if next(links) ~= nil then
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

function M.validate_proxy_link(link)
    if type(link) ~= "string" or not link:match("^%w+://") then return false, "Invalid proxy link format" end
    if #link > M.LINK_MAX_SIZE then return false, "Proxy link exceeds size limit" end
    if link:find("%c") then return false, "Proxy link contains invalid control bytes" end
    return true
end

local function find_proxy_slot(section_name, proxy_type, slot_index)
    if not LIB.sanitize_section_name(section_name) or type(slot_index) ~= "number" or
        slot_index < 0 or slot_index > 999 or slot_index ~= math.floor(slot_index) then return nil, "Invalid proxy slot" end
    local config_path = "/etc/config/podkop"
    local content, read_err = SRV.read_file(config_path, 1048576)
    if not content then return nil, "Cannot read config: " .. tostring(read_err) end
    local valid, config_err = LIB.validate_uci_config(content)
    if not valid then return nil, "Invalid source config: " .. tostring(config_err) end
    local statements, parse_err = LIB.uci_statements(content, true)
    if not statements then return nil, parse_err end
    local list_name
    if proxy_type == "url" then list_name = "proxy_string"
    elseif proxy_type == "urltest" then list_name = "urltest_proxy_links"
    elseif proxy_type == "selector" then list_name = "selector_proxy_links"
    else return nil, "Unknown proxy type" end
    local in_section, count = false, 0
    for _, statement in ipairs(statements) do
        local tokens = statement.tokens
        if tokens[1] == "config" then
            in_section = tokens[2] == "section" and tokens[3] == section_name
        elseif in_section and tokens[2] == list_name and
            tokens[1] == (proxy_type == "url" and "option" or "list") then
            if count == slot_index then
                return content, statement
            end
            count = count + 1
        end
    end
    return nil, "Proxy link not found in config", "missing_slot"
end

function M.current_proxy_link(section_name, proxy_type, slot_index)
    local content, statement, kind = find_proxy_slot(section_name, proxy_type, slot_index)
    if not content then return nil, statement, nil, kind end
    return statement.tokens[3], nil, content
end

function M.prepare_proxy_link(section_name, proxy_type, slot_index, new_link)
    local valid, link_err = M.validate_proxy_link(new_link)
    if not valid then return nil, link_err end
    local content, statement = find_proxy_slot(section_name, proxy_type, slot_index)
    if not content then return nil, statement end
    local tokens = statement.tokens
    local old = content:sub(statement.first, statement.last)
    local ending = old:sub(-2) == "\r\n" and "\r\n" or (old:sub(-1) == "\n" and "\n" or "")
    local replacement = (old:match("^[ \t]*") or "\t") .. tokens[1] .. " " .. tokens[2] .. " " .. LIB.shell_escape(new_link)
    if statement.comment then replacement = replacement .. " " .. content:sub(statement.comment, statement.last - #ending) end
    local candidate = content:sub(1, statement.first - 1) .. replacement .. ending .. content:sub(statement.last + 1)
    local ok, err = LIB.validate_uci_config(candidate)
    if not ok then return nil, "Invalid candidate config: " .. err end
    return candidate, nil, content, tokens[3]
end

function M.replace_proxy_link(section_name, proxy_type, slot_index, new_link, backup_path, expected_link)
    -- Reject untrusted bytes before lock acquisition or any configuration IO.
    local valid, link_err = M.validate_proxy_link(new_link)
    if not valid then return false, link_err end
    return locked_publication("podkop", function()
        local candidate, prepare_err, original, current = M.prepare_proxy_link(section_name, proxy_type, slot_index, new_link)
        if not candidate then return false, prepare_err end
        if expected_link ~= nil and current ~= expected_link then return false, "Proxy slot changed during update" end
        local path = "/etc/config/podkop"
        local stage, stage_err = SRV.stage_file(path, candidate, { suffix = ".tmp" })
        if not stage then return false, stage_err end
        local live, read_err = SRV.read_file(path, M.SUB_MAX_SIZE)
        if live ~= original then
            SRV.discard_stage(stage)
            return false, read_err or "Podkop config changed during update"
        end
        if backup_path then
            local backed, backup_err = SRV.write_file_atomic(backup_path, original, { suffix = ".tmp" })
            if not backed then
                SRV.discard_stage(stage)
                return false, "Cannot create subscription backup: " .. tostring(backup_err)
            end
        end
        live, read_err = SRV.read_file(path, M.SUB_MAX_SIZE)
        if live ~= original then
            SRV.discard_stage(stage)
            return false, read_err or "Podkop config changed during update"
        end
        local published, publish_err = SRV.publish_file(stage, path)
        if not published then SRV.discard_stage(stage) end
        return published, publish_err, published
    end)
end

function M.backup_file(src, dst)
    return SRV.backup_to(src, dst, true)
end

function M.backup_config()
    return M.backup_file("/etc/config/podkop", "/etc/config/podkop.auto-backup")
end

function M.backup_stubby_config()
    return M.backup_file("/etc/config/stubby", "/etc/config/stubby.auto-backup")
end

function M.do_update_subscription(section_name, slot_index, sub_url, proxy_name)
    if not LIB.sanitize_section_name(section_name) then
        return nil, "invalid section name"
    end
    if not NET.valid_url(sub_url) then return nil, "invalid url" end
    local raw_proxies = nil
    local max_retries = 3
    local last_err = "download failed"
    local success_attempt = 0
    for attempt = 1, max_retries do
        local data, download_err = NET.fetch(sub_url, M.SUB_MAX_SIZE, 15, "sing-box")
        if data then
            if #data > 0 then
                local proxies, parse_err = M.parse_subscription_raw(data)
                if #proxies > 0 then
                    raw_proxies = proxies
                    success_attempt = attempt
                    break
                end
                last_err = parse_err or "no proxies found"
                if parse_err then return nil, last_err, attempt end
            else
                last_err = "empty response"
            end
        else
            last_err = download_err or "download failed"
            if last_err:match("size limit") then return nil, last_err, attempt end
        end

        if attempt < max_retries then
            os.execute("sleep 10 2>/dev/null")
        end
    end

    if not raw_proxies then
        return nil, last_err .. " (" .. max_retries .. " retries)"
    end

    local proxies = raw_proxies

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
    if not LIB.sanitize_section_name(section_name) or type(slot_index) ~= "number" or
        slot_index < 0 or slot_index > 999 or slot_index ~= math.floor(slot_index) then
        return false, "Invalid proxy slot"
    end
    return locked_publication("subscriptions", function()
        local subs, read_err = M.read_subs(subs_file)
        if not subs then return false, read_err end
        local slots, slots_err = M.subscription_slots(subs, section_name)
        if not slots then return false, slots_err end
        local existing = slots[slot_index + 1]
        if type(existing) ~= "table" or not existing.subscription_url then return false, "Subscription not found" end
        existing.last_updated = os.date("%H:%M %d.%m.%Y") .. " (" .. M.clean_log_field(mode) .. ")"
        return M.write_subs(subs, subs_file)
    end)
end

local LOG_MAX_SIZE = 4194304

local function log_bytes(log_file)
    local data, err, errno = SRV.read_file(log_file, LOG_MAX_SIZE)
    if data then return data end
    if errno == 2 then return "" end
    return nil, "Cannot read subscription log: " .. tostring(err)
end

local function trim_log(data, max_events)
    if max_events <= 0 then return "" end
    local starts = {}
    for first, line in data:gmatch("()([^\n]+)") do
        if not line:match("^%s") then starts[#starts + 1] = first end
    end
    if #starts <= max_events then return data end
    return data:sub(starts[#starts - max_events + 1])
end

function M.rotate_log(log_file, max_events)
    return locked_publication("subscriptions", function()
        local data, read_err = log_bytes(log_file)
        if not data then return false, read_err end
        local trimmed = trim_log(data, math.max(0, math.floor(tonumber(max_events) or 0)))
        if trimmed == data then return true end
        local written, write_err = SRV.write_file_atomic(log_file, trimmed)
        return written, write_err, written
    end)
end

function M.append_log(log_file, max_events, text)
    if type(text) ~= "string" then return false, "Subscription log entry must be text" end
    return locked_publication("subscriptions", function()
        local data, read_err = log_bytes(log_file)
        if not data then return false, read_err end
        data = trim_log(data, math.max(1, math.floor(tonumber(max_events) or 1)) - 1)
        if data ~= "" and data:sub(-1) ~= "\n" then data = data .. "\n" end
        data = data .. text .. "\n"
        if #data > LOG_MAX_SIZE then return false, "Subscription log exceeds size limit" end
        local written, write_err = SRV.write_file_atomic(log_file, data)
        return written, write_err, written
    end)
end

function M.write_sub_backup()
    return M.backup_file("/etc/config/podkop", "/etc/config/podkop.sub-backup")
end

function M.update_all_subscriptions(subs_file, log_file, log_max, mode)
    local result = { success = true, updated = 0, unchanged = 0, failed = 0,
        skipped = 0, need_restart = false, details = {} }
    local function read_jobs()
        local subs, read_err = M.read_subs(subs_file)
        if not subs then return nil, read_err end
        local pending = {}
        for _, sec in ipairs(M.get_proxy_sections()) do
            local slots, slots_err = M.subscription_slots(subs, sec.name)
            if not slots then return nil, slots_err end
            local max_n, count_err = M.slot_count(sec.proxy_links)
            if not max_n then return nil, count_err end
            for i = 1, max_n do
                local entry, link = slots[i], sec.proxy_links[i]
                if type(entry) == "table" and entry.subscription_url and entry.subscription_url ~= "" and link ~= nil then
                    pending[#pending + 1] = { section = sec.name, proxy_type = sec.proxy_config_type,
                        slot = i - 1, link = link, url = entry.subscription_url, name = entry.proxy_name }
                end
            end
        end
        return pending
    end
    local read_err
    local jobs, snapshot_err, snapshot_unknown = SRV.with_lock("subscriptions", function()
        local pending
        pending, read_err = read_jobs()
        return pending, read_err
    end)
    if not jobs then
        result.success, result.error = false, snapshot_err or "Cannot read subscription state"
        if read_err and read_err ~= snapshot_err then result.error = read_err .. "\n" .. result.error end
        result.unknown = snapshot_unknown or nil
        return result
    end

    local need_backup = true
    for _, job in ipairs(jobs) do
        -- HTTP waits/retries never hold a state/config lock. A successful manual
        -- Detach/Attach/Save during this wait is authoritative at reconciliation.
        local proxy, fetch_err, attempt = M.do_update_subscription(job.section, job.slot, job.url, job.name)
        local config_applied, state_applied = false, false
        local function reconcile_current()
            local subs, read_err = M.read_subs(subs_file)
            if not subs then return { fatal = true, error = read_err } end
            local slots, slots_err = M.subscription_slots(subs, job.section)
            if not slots then return { fatal = true, error = slots_err } end
            local entry = slots[job.slot + 1]
            if type(entry) ~= "table" or entry.subscription_url ~= job.url or entry.proxy_name ~= job.name then
                return { status = "skipped", reason = "Subscription association changed during download" }
            end
            local current_section
            for _, sec in ipairs(M.get_proxy_sections()) do
                if sec.name == job.section then current_section = sec; break end
            end
            if not current_section or current_section.proxy_config_type ~= job.proxy_type or
                current_section.proxy_links[job.slot + 1] ~= job.link then
                return { status = "skipped", reason = "Proxy slot changed during download" }
            end
            local function apply_current()
                local live_link, live_err, _, live_kind = M.current_proxy_link(job.section, job.proxy_type, job.slot)
                if not live_link then
                    if live_kind == "missing_slot" then return { status = "skipped", reason = "Proxy slot removed during download" } end
                    return { fatal = true, error = live_err }
                end
                if live_link ~= job.link then return { status = "skipped", reason = "Proxy link changed during download" } end
                if not proxy or not proxy.link then return { status = "failed", error = fetch_err or "Subscription download failed" } end
                local valid, link_err = M.validate_proxy_link(proxy.link)
                if not valid then return { status = "failed", error = link_err } end
                -- Retain every unrelated field from the *current* state. Stage
                -- it before config mutation so write/close failures are a barrier.
                entry.last_updated = os.date("%H:%M %d.%m.%Y") .. " (" .. M.clean_log_field(mode) .. ")"
                local stage, stage_err = M.stage_subs(subs, subs_file)
                if not stage then return { fatal = true, error = stage_err } end
                local changed = live_link ~= proxy.link
                if changed then
                    local replaced, replace_err, replace_applied, replace_unknown = M.replace_proxy_link(job.section, job.proxy_type,
                        job.slot, proxy.link, need_backup and "/etc/config/podkop.sub-backup" or nil, job.link)
                    config_applied = replaced or replace_applied == true
                    if not replaced then
                        SRV.discard_stage(stage)
                        return { fatal = true, error = replace_err, unknown = replace_unknown }
                    end
                end
                local saved, save_err = SRV.publish_file(stage, subs_file)
                if not saved then
                    SRV.discard_stage(stage)
                    return { fatal = true, error = "Cannot save subscription state: " .. tostring(save_err) }
                end
                state_applied = true
                return { status = changed and "updated" or "unchanged" }
            end
            local observed
            local applied, config_err, config_uncertain = SRV.with_lock("podkop", function()
                observed = apply_current()
                return observed
            end)
            if not applied then
                observed = observed or {}
                observed.fatal, observed.status = true, nil
                observed.error = observed.error and (observed.error .. "\n" .. tostring(config_err)) or config_err
                observed.unknown = config_uncertain or observed.unknown or nil
                return observed
            end
            return applied
        end
        local observed
        local outcome, lock_err, uncertain = SRV.with_lock("subscriptions", function()
            observed = reconcile_current()
            return observed
        end)
        if not outcome then
            outcome = observed or {}
            outcome.fatal, outcome.status = true, nil
            outcome.error = outcome.error and (outcome.error .. "\n" .. tostring(lock_err)) or lock_err
            outcome.unknown = uncertain or outcome.unknown or nil
        end
        if config_applied then
            need_backup = false
            result.need_restart, result.applied = true, true
            result.updated = result.updated + 1
        end
        if state_applied then result.applied = true end
        local detail = { section = job.section, slot = job.slot, proxy = M.clean_log_field(job.name),
            status = outcome.status or "failed", error = outcome.error and M.clean_log_field(outcome.error), reason = outcome.reason }
        if attempt and attempt > 1 and (detail.status == "updated" or detail.status == "unchanged") then
            detail.status = detail.status .. " (retry " .. attempt .. ")"
        end
        result.details[#result.details + 1] = detail
        if outcome.fatal then
            result.success, result.error = false, outcome.error or "Subscription update failed"
            result.failed = result.failed + 1
            result.unknown = outcome.unknown or nil
            result.restart_required = result.need_restart
            return result
        elseif outcome.status == "unchanged" then result.unchanged = result.unchanged + 1
        elseif outcome.status == "skipped" then result.skipped = result.skipped + 1
        elseif outcome.status == "failed" then result.failed = result.failed + 1 end
    end

    local log_text = os.date("%H:%M %d.%m.%Y") .. "|" .. M.clean_log_field(mode) .. "|updated=" .. result.updated
        .. "|unchanged=" .. result.unchanged .. "|failed=" .. result.failed
    local by_section = {}
    for _, d in ipairs(result.details) do
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
            if d.error or d.reason then log_text = log_text .. " (" .. M.clean_log_field(d.error or d.reason) .. ")" end
        end
    end
    local logged, log_err, log_applied, log_unknown = M.append_log(log_file, log_max, log_text)
    if not logged then
        result.success, result.error = false, "Cannot write subscription update log"
        result.error_details = log_err
        result.log_applied = log_applied
        result.unknown = log_unknown
        result.restart_required = result.need_restart
    end
    return result
end

function M.apply_files_from_dir(extract_dir, relaxed, paths)
    local sys = require("luci.sys")
    local find_cmd = "find " .. M.shell_escape(extract_dir) .. " -type f \\! -type l 2>/dev/null"
    local raw = paths and table.concat(paths, "\n") or sys.exec(find_cmd)
    local prefix_len = #extract_dir + 1
    local copied = 0

    for line in raw:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then
            local rel = paths and line or line:sub(prefix_len):match("^/?(.*)")
            if rel ~= "" and M._is_valid_update_path(rel, relaxed) then
                local dest = "/" .. rel
                local dest_dir = dest:match("^(.+)/[^/]+$")
                if dest_dir then
                    local out = sys.exec("mkdir -p " .. M.shell_escape(dest_dir) .. " 2>/dev/null; printf '\\nPT_EXIT:%s\\n' \"$?\"")
                    if not out:match("\nPT_EXIT:0\n$") then return copied, "Cannot create directory: " .. dest_dir end
                end
                local data, read_err = SRV.read_file(paths and (extract_dir .. "/" .. rel) or line, ARCHIVE.MAX_FILE_SIZE)
                if data then
                    -- Ship defaults for first install, preserve app-owned UCI on
                    -- self-update (appearance, visibility and Fragment settings).
                    local preserve = false
                    if rel == "etc/config/podkop-tweaker" or rel == "etc/config/podkop-fragment" then
                        local existing, existing_err, errno = io.open(dest, "rb")
                        if existing then
                            if not existing:close() then return copied, "Cannot close existing app configuration" end
                            preserve = true
                        elseif errno ~= 2 then return copied, "Cannot read existing app configuration: " .. tostring(existing_err) end
                    end
                    if preserve then
                        -- Recognized preservation counts as a completed member,
                        -- but is intentionally not added to files_copied.
                    else
                        local ok, err = SRV.write_file_atomic(dest, data, { suffix = ".tmp-update",
                            executable = rel:match("^usr/bin/") ~= nil or rel:match("^etc/init%.d/") ~= nil or rel:match("^etc/rc%.d/") ~= nil })
                        if not ok then return copied, "Cannot apply " .. rel .. ": " .. tostring(err) end
                        copied = copied + 1
                    end
                else return copied, "Cannot read " .. rel .. ": " .. tostring(read_err) end
            else return copied, "Update path is not allowed: " .. rel end
        end
    end

    return copied
end

function M._is_valid_update_path(rel_path, relaxed)
    return ARCHIVE.is_valid_path(rel_path, relaxed)
end

return M
