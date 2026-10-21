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

M.LOG_MAX_SIZE = 4194304
local completion_contexts = setmetatable({}, { __mode = "k" })
local MAIN = {}
local function invocation_owner() return coroutine.running() or MAIN end

function M.new_operation_id()
    local opened, fd, open_err = pcall(io.open, "/dev/urandom", "rb")
    if not opened or not fd then return nil, "Cannot open operation ID source: " .. tostring(opened and open_err or fd) end
    local read_ok, bytes, read_err = pcall(fd.read, fd, 16)
    local close_ok, closed, close_err = pcall(fd.close, fd)
    local errors = {}
    if not read_ok or type(bytes) ~= "string" or #bytes ~= 16 or read_err ~= nil then
        errors[#errors + 1] = "Cannot read exactly 16 operation ID bytes: " .. tostring(read_ok and (read_err or "Short random read") or bytes)
    end
    if not close_ok or not closed then
        errors[#errors + 1] = "Cannot close operation ID source: " .. tostring(close_ok and close_err or closed)
    end
    if #errors > 0 then return nil, table.concat(errors, "\n") end
    return (bytes:gsub(".", function(byte) return string.format("%02x", byte:byte()) end))
end

local function counter(value)
    return type(value) == "string" and #value <= 10 and value:match("^%d+$") and tonumber(value) or nil
end

-- An extension is accepted only as a complete keyed schema. A malformed new
-- header must never acquire the historical meaning of a five-field header.
function M.parse_log_header(line)
    if type(line) ~= "string" then return nil end
    local fields = {}
    for field in (line .. "|"):gmatch("(.-)|") do fields[#fields + 1] = field end
    if #fields < 5 or not fields[1]:match("^%d%d:%d%d %d%d%.%d%d%.%d%d%d%d$") or
        (fields[2] ~= "manual" and fields[2] ~= "auto") then return nil end
    local updated = counter(fields[3]:match("^updated=(.*)$"))
    local unchanged = counter(fields[4]:match("^unchanged=(.*)$"))
    local failed = counter(fields[5]:match("^failed=(.*)$"))
    if not updated or not unchanged or not failed then return nil end
    local event = { ts = fields[1], mode = fields[2], updated = updated, unchanged = unchanged, failed = failed }
    if #fields == 5 then event.legacy = true; return event end
    if #fields ~= 10 then return nil end
    local values, allowed = {}, { id = true, state = true, service = true, skipped = true, outcome = true }
    for i = 6, #fields do
        local key, value = fields[i]:match("^([a-z_]+)=(.+)$")
        if not allowed[key] or values[key] then return nil end
        values[key] = value
    end
    if type(values.id) ~= "string" or #values.id ~= 32 or not values.id:match("^[0-9a-f]+$") or
        (values.state ~= "pending" and values.state ~= "finished") or
        not ({ pending = true, requested = true, failed = true, unknown = true, not_required = true })[values.service] or
        not counter(values.skipped) or
        not ({ pending = true, ok = true, partial = true, failed = true })[values.outcome] then return nil end
    if values.state == "pending" then
        if values.service ~= "pending" or values.outcome ~= "pending" then return nil end
    elseif values.outcome == "pending" then return nil end
    event.id, event.state, event.service = values.id, values.state, values.service
    event.skipped, event.outcome = tonumber(values.skipped), values.outcome
    return event
end

local function log_bytes(log_file)
    local data, err, errno = SRV.read_file(log_file, M.LOG_MAX_SIZE)
    if data then return data end
    if errno == 2 then return "" end
    return nil, "Cannot read subscription log: " .. tostring(err)
end

local function log_blocks(data)
    local starts, blocks = {}, {}
    for first, line in data:gmatch("()([^\n]+)") do
        if not line:match("^%s") then starts[#starts + 1] = first end
    end
    if #starts == 0 then return data ~= "" and { data } or {} end
    if starts[1] > 1 then blocks[#blocks + 1] = data:sub(1, starts[1] - 1) end
    for i, first in ipairs(starts) do blocks[#blocks + 1] = data:sub(first, (starts[i + 1] or (#data + 1)) - 1) end
    return blocks
end

local function header_of(block) return (block:match("^([^\n]*)") or ""):gsub("\r$", "") end

local function header_has(block, key, value)
    local index = 0
    for field in (header_of(block) .. "|"):gmatch("(.-)|") do
        index = index + 1
        if index > 5 and field == key .. "=" .. value then return true end
    end
    return false
end

local function retained_limit(value)
    return math.min(25, math.max(0, math.floor(tonumber(value) or 0)))
end

local function trim_log(data, max_events)
    local blocks, completed, out = log_blocks(data), 0, {}
    for i = #blocks, 1, -1 do
        -- Preserve even a malformed pending extension for inspection. It is not
        -- parsed as a completed/legacy event by any reader.
        if header_has(blocks[i], "state", "pending") then out[i] = blocks[i]
        else
            completed = completed + 1
            if completed <= max_events then out[i] = blocks[i] end
        end
    end
    local kept = {}
    for i = 1, #blocks do if out[i] then kept[#kept + 1] = out[i] end end
    return table.concat(kept)
end

function M.rotate_log(log_file, max_events)
    return locked_publication("subscriptions", function()
        local data, read_err = log_bytes(log_file)
        if not data then return false, read_err end
        local trimmed = trim_log(data, retained_limit(max_events))
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
        local event = M.parse_log_header(header_of(text))
        if event and event.id then
            for _, block in ipairs(log_blocks(data)) do
                if header_has(block, "id", event.id) then return false, "Duplicate subscription operation ID" end
            end
        end
        if data ~= "" and data:sub(-1) ~= "\n" then data = data .. "\n" end
        data = trim_log(data .. text .. "\n", math.max(1, retained_limit(max_events)))
        if #data > M.LOG_MAX_SIZE then return false, "Subscription log exceeds size limit" end
        local written, write_err = SRV.write_file_atomic(log_file, data)
        return written, write_err, written
    end)
end

local function diagnostics(existing, extra)
    if not extra or extra == "" then return existing end
    return existing and (existing .. "\n" .. tostring(extra)) or tostring(extra)
end

local function operation_outcome(result)
    if result.success == true and result.failed == 0 and result.skipped == 0 then return "ok" end
    if result.applied or result.updated > 0 or result.unchanged > 0 or result.skipped > 0 then return "partial" end
    return "failed"
end

local function admit_operation(result, log_file, log_max, mode)
    local id, err = M.new_operation_id()
    if type(id) ~= "string" or #id ~= 32 or not id:match("^[0-9a-f]+$") then
        result.success, result.error = false, "Cannot generate subscription operation ID"
        result.error_details = err or "Invalid operation ID"
        return nil
    end
    result.operation_id = id
    local context = { owner = invocation_owner(), id = id, ts = os.date("%H:%M %d.%m.%Y"),
        mode = mode, log_file = log_file, log_max = log_max }
    completion_contexts[result] = context
    return context
end

local function event_text(context, result, state)
    local text = context.ts .. "|" .. context.mode .. "|updated=" .. result.updated .. "|unchanged=" .. result.unchanged
        .. "|failed=" .. result.failed .. "|id=" .. context.id .. "|state=" .. state .. "|service=" .. result.service
        .. "|skipped=" .. result.skipped .. "|outcome=" .. result.outcome
    local by_section, names = {}, {}
    for _, detail in ipairs(result.details) do
        if not by_section[detail.section] then by_section[detail.section] = {}; names[#names + 1] = detail.section end
        by_section[detail.section][#by_section[detail.section] + 1] = detail
    end
    table.sort(names)
    for _, name in ipairs(names) do
        text = text .. "\n  " .. M.clean_log_field(name) .. ":"
        for _, detail in ipairs(by_section[name]) do
            text = text .. "\n    " .. M.clean_log_field(detail.proxy) .. ": " .. M.clean_log_field(detail.status)
            if detail.error or detail.reason then text = text .. " (" .. M.clean_log_field(detail.error or detail.reason) .. ")" end
        end
    end
    if result.error then
        text = text .. "\n  operation:\n    " .. M.clean_log_field(result.error)
        if result.error_details then text = text .. " (" .. M.clean_log_field(result.error_details) .. ")" end
    end
    if result.restart then
        text = text .. "\n  service:\n    podkop: " .. result.service
        if result.restart.error then text = text .. " (" .. M.clean_log_field(result.restart.error) .. ")" end
        if result.restart.details then text = text .. " (" .. M.clean_log_field(result.restart.details) .. ")" end
    end
    return text
end

local function journal_failure(result, summary, err, unknown)
    result.success = false
    if result.error then result.error_details = diagnostics(result.error_details, summary .. ": " .. tostring(err))
    else result.error, result.error_details = summary, err end
    result.unknown = result.unknown or unknown or nil
    result.outcome = operation_outcome(result)
    result.journal.error, result.journal.details = summary, err
    result.journal.unknown = result.journal.unknown or unknown or nil
    result.restart_required = result.need_restart and result.service ~= "requested" or nil
end

local function record_operation(result)
    local context = completion_contexts[result]
    local pending = result.success == true and result.need_restart
    result.service = result.need_restart and "pending" or "not_required"
    result.outcome = pending and "pending" or operation_outcome(result)
    result.restart_required = result.success ~= true and result.need_restart or nil
    local text = event_text(context, result, pending and "pending" or "finished")
    local logged, err, published, unknown = M.append_log(context.log_file, context.log_max, text)
    local recorded = logged or published == true
    result.log_applied = recorded or nil
    result.journal = { recorded = recorded, finalized = recorded and not pending }
    if not logged then journal_failure(result, "Cannot write subscription update log", err, unknown)
    elseif pending then context.pending, context.ready = text .. "\n", true end
    return result
end

local function finalize_event(context, text)
    return locked_publication("subscriptions", function()
        local data, read_err = log_bytes(context.log_file)
        if not data then return false, read_err end
        local blocks, found = log_blocks(data), nil
        for i, block in ipairs(blocks) do
            if header_has(block, "id", context.id) then
                if found then return false, "Duplicate subscription operation ID during finalization" end
                found = i
            end
        end
        if not found then return false, "Subscription operation ID missing during finalization" end
        if blocks[found] == text then return true, nil, true end
        if blocks[found] ~= context.pending then return false, "Subscription pending event changed during finalization" end
        table.remove(blocks, found)
        local current = table.concat(blocks)
        if current ~= "" and current:sub(-1) ~= "\n" then current = current .. "\n" end
        current = trim_log(current .. text, math.max(1, retained_limit(context.log_max)))
        if #current > M.LOG_MAX_SIZE then return false, "Subscription log exceeds size limit" end
        local written, err = SRV.write_file_atomic(context.log_file, current)
        return written, err, written
    end)
end

-- Only the exact invocation's private context can consume its restart right.
-- Durable pending records are observations, never restart/recovery commands.
function M.finish_subscription_update(result)
    local context = completion_contexts[result]
    if not context or context.owner ~= invocation_owner() or context.consumed or not context.ready then return result end
    context.consumed = true
    local observed, called
    local ran, restart, lock_err, uncertain = pcall(SRV.with_lock, "podkop", function()
        called = true
        local ok, response = pcall(SRV.restart_service, "podkop")
        observed = ok and type(response) == "table" and response or {
            success = false, error = "Cannot capture Podkop restart result", details = tostring(response),
            command_result_known = false, unknown = true }
        return observed
    end)
    if not ran then lock_err, restart, uncertain = restart, nil, true end
    if not restart then
        restart = observed or { command_result_known = false }
        restart.success = false
        restart.error = restart.error or (restart.restarting and "Podkop restart requested, but lock release failed" or "Podkop restart lock failed")
        restart.details = diagnostics(restart.details, lock_err)
        restart.unknown = restart.unknown or uncertain or nil
    end
    result.restart = restart
    if restart.command_result_known == true and type(restart.command_exit_code) == "number" then
        result.service = restart.command_exit_code == 0 and "requested" or "failed"
    else result.service = called and "unknown" or "failed" end
    if result.service == "unknown" then restart.unknown = true end
    for key, value in pairs(restart) do
        if key ~= "success" and key ~= "error" and key ~= "details" and key ~= "unknown" and key ~= "applied" then result[key] = value end
    end
    result.unknown = result.unknown or restart.unknown or nil
    if restart.success ~= true or result.service ~= "requested" then
        result.success = false
        result.error = result.error or restart.error or "Podkop restart result is unknown"
        result.error_details = diagnostics(result.error_details, restart.details)
    end
    result.restarted = restart.success == true and result.service == "requested"
    result.restart_required = result.service ~= "requested" or nil
    result.outcome = operation_outcome(result)
    local text = event_text(context, result, "finished") .. "\n"
    local finalized, err, published, unknown = finalize_event(context, text)
    result.journal.finalized = finalized or published == true
    if not finalized then journal_failure(result, "Cannot finalize subscription update log", err, unknown) end
    return result
end

function M.write_sub_backup()
    return M.backup_file("/etc/config/podkop", "/etc/config/podkop.sub-backup")
end

function M.update_all_subscriptions(subs_file, log_file, log_max, mode)
    local result = { success = true, updated = 0, unchanged = 0, failed = 0,
        skipped = 0, need_restart = false, details = {}, service = "not_required", outcome = "failed",
        journal = { recorded = false, finalized = false }, restarted = false }
    if mode ~= "manual" and mode ~= "auto" then
        result.success, result.error = false, "Invalid subscription update mode"
        return result
    end
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
    if not admit_operation(result, log_file, log_max, mode) then return result end

    local need_backup = true
    for _, job in ipairs(jobs) do
        -- HTTP waits/retries never hold a state/config lock. A successful manual
        -- Detach/Attach/Save during this wait is authoritative at reconciliation.
        local config_applied, state_applied = false, false
        local proxy, fetch_err, attempt
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
                observed.fatal = true
                observed.error = observed.error and (observed.error .. "\n" .. tostring(config_err)) or config_err
                observed.unknown = config_uncertain or observed.unknown or nil
                return observed
            end
            return applied
        end
        local ran, outcome = pcall(function()
            proxy, fetch_err, attempt = M.do_update_subscription(job.section, job.slot, job.url, job.name)
            local observed
            local reconciled, lock_err, uncertain = SRV.with_lock("subscriptions", function()
                observed = reconcile_current()
                return observed
            end)
            if not reconciled then
                reconciled = observed or {}
                reconciled.fatal = true
                reconciled.error = diagnostics(reconciled.error, lock_err)
                reconciled.unknown = uncertain or reconciled.unknown or nil
            end
            return reconciled
        end)
        if not ran then outcome = { fatal = true, error = tostring(outcome), unknown = true,
            status = state_applied and (config_applied and "updated" or "unchanged") or nil } end
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
        if outcome.status == "unchanged" then result.unchanged = result.unchanged + 1
        elseif outcome.status == "skipped" then result.skipped = result.skipped + 1
        elseif outcome.status == "failed" or not outcome.status then result.failed = result.failed + 1 end
        if outcome.fatal then
            result.success, result.error = false, outcome.error or "Subscription update failed"
            result.unknown = outcome.unknown or nil
            result.restart_required = result.need_restart
            return record_operation(result)
        end
    end

    return record_operation(result)
end

function M.attach_subscription(subs_file, log_file, log_max, section_name, slot_index, subscription_url, proxy_name, new_link)
    slot_index = tonumber(slot_index or "-1")
    if not slot_index or slot_index < 0 or slot_index > 999 or slot_index ~= math.floor(slot_index) or
        section_name == "" or new_link == "" then return { error = "Missing required parameters" } end
    if not LIB.sanitize_section_name(section_name) then return { error = "Invalid section name" } end
    local valid, link_err = M.validate_proxy_link(new_link)
    if not valid then return { error = link_err } end
    if not NET.valid_url(subscription_url) then return { error = "Only HTTP(S) URLs allowed" } end
    if proxy_name == nil then proxy_name = "" end
    if type(proxy_name) ~= "string" or #proxy_name > 1024 then return { error = "Invalid proxy name" } end

    local admission
    local snapshot, lock_err, lock_unknown = SRV.with_lock("subscriptions", function()
        local subs, read_err = M.read_subs(subs_file)
        if not subs then admission = { error = read_err }; return admission end
        local slots, slots_err = M.subscription_slots(subs, section_name)
        if not slots then admission = { error = slots_err }; return admission end
        local section
        for _, sec in ipairs(M.get_proxy_sections()) do if sec.name == section_name then section = sec; break end end
        if not section then admission = { error = "Section not found or not a proxy section" }; return admission end
        local current = section.proxy_links[slot_index + 1]
        if type(current) ~= "string" then admission = { error = "Proxy slot not found" }; return admission end
        local live, err = M.current_proxy_link(section_name, section.proxy_config_type, slot_index)
        if not live then admission = { error = err }; return admission end
        if live ~= current then admission = { error = "Proxy slot changed; refresh before attaching" }; return admission end
        admission = { link = current, proxy_type = section.proxy_config_type }
        return admission
    end)
    if not snapshot then
        admission = admission or {}
        admission.success, admission.error = false, admission.error or "Subscription lock failed"
        admission.error_details = diagnostics(admission.error_details, lock_err)
        admission.unknown = lock_unknown or nil
        return admission
    end
    if snapshot.error then return snapshot end

    local result = { success = true, updated = 0, unchanged = 0, failed = 0, skipped = 0, need_restart = false,
        details = {}, service = "not_required", outcome = "failed", journal = { recorded = false, finalized = false }, restarted = false }
    if not admit_operation(result, log_file, log_max, "manual") then return result end
    local config_applied, state_applied, observed = false, false, nil
    local ran, outcome, err, unknown = pcall(SRV.with_lock, "subscriptions", function()
        local function attach_current()
            local subs, read_err = M.read_subs(subs_file)
            if not subs then return { error = read_err } end
            local slots, slots_err = M.subscription_slots(subs, section_name)
            if not slots then return { error = slots_err } end
            local function publish()
                local live, live_err = M.current_proxy_link(section_name, snapshot.proxy_type, slot_index)
                if not live then return { error = live_err } end
                if live ~= snapshot.link then return { error = "Proxy slot changed; refresh before attaching" } end
                local entry = type(slots[slot_index + 1]) == "table" and slots[slot_index + 1] or {}
                entry.subscription_url, entry.proxy_name = subscription_url, proxy_name
                entry.last_updated = os.date("%H:%M %d.%m.%Y") .. " (manual)"
                for i = 1, slot_index do if slots[i] == nil then slots[i] = false end end
                slots[slot_index + 1], subs[section_name] = entry, slots
                local stage, stage_err = M.stage_subs(subs, subs_file)
                if not stage then return { error = "Failed to save data", details = stage_err } end
                local changed = live ~= new_link
                if changed then
                    local replaced, replace_err, published, uncertain = M.replace_proxy_link(section_name, snapshot.proxy_type,
                        slot_index, new_link, "/etc/config/podkop.sub-backup", live)
                    config_applied = replaced or published == true
                    if not replaced then
                        SRV.discard_stage(stage)
                        return { error = replace_err, unknown = uncertain }
                    end
                end
                local saved, save_err = SRV.publish_file(stage, subs_file)
                if not saved then
                    SRV.discard_stage(stage)
                    return { error = "Failed to save data", details = save_err }
                end
                state_applied = true
                return { status = changed and "updated" or "unchanged" }
            end
            local applied
            local saved, config_err, uncertain = SRV.with_lock("podkop", function() applied = publish(); return applied end)
            if not saved then
                applied = applied or {}
                applied.error = applied.error or "Podkop lock failed"
                applied.details = diagnostics(applied.details, config_err)
                applied.unknown = applied.unknown or uncertain or nil
                return applied
            end
            return saved
        end
        observed = attach_current()
        return observed
    end)
    if not ran then err, outcome, unknown = outcome, nil, true end
    if not outcome then
        outcome = observed or {}
        outcome.status = outcome.status or (state_applied and (config_applied and "updated" or "unchanged") or nil)
        outcome.error = outcome.error or "Subscription lock failed"
        outcome.details = diagnostics(outcome.details, err)
        outcome.unknown = outcome.unknown or unknown or nil
    end
    result.applied = config_applied or state_applied or nil
    result.need_restart = config_applied
    result.updated = config_applied and 1 or 0
    if outcome.status == "unchanged" then result.unchanged = 1
    elseif not outcome.status then result.failed = 1 end
    if outcome.error then result.success, result.error, result.error_details = false, outcome.error, outcome.details end
    result.unknown = outcome.unknown
    result.details[1] = { section = section_name, slot = slot_index, proxy = M.clean_log_field(proxy_name),
        status = outcome.status or "failed", error = outcome.error and M.clean_log_field(outcome.error) }
    return record_operation(result)
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
