-- Podkop Tweaker | v4.10.2 | 17.10.2026 | Checked service application and immutable outbound/Fragment queries
-- Hybrid exceptions kept as-is: read_config, export_config, download_backup (transport endpoints)

local H = require("podkop-tweaker.http")
local SRV = require("podkop-tweaker.services")
local LIB = require("podkop-tweaker.lib")

local M = {}
M.CONFIG_MAX_SIZE = SRV.SINGBOX_MAX_SIZE

function M.read_config()
    H.send_text_file(SRV.SINGBOX_CONFIG, { limit = M.CONFIG_MAX_SIZE, require_nonempty = true })
end

function M.save_config(content)
    local ok, err = SRV.singbox_content_check(content, "Configuration is empty")
    if not ok then
        return { error = err }
    end
    return SRV.apply_service(SRV.singbox, content, { skip_unchanged = true })
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
    local ok, err = SRV.singbox_content_check(content, "Empty content")
    if not ok then
        return { error = err }
    end
    return SRV.apply_service(SRV.singbox, content)
end

local JQ_OBJECT = 'if length == 1 and (.[0] | type == "object") then .[0] else error("Config must contain exactly one JSON object") end'
local JQ_OUTBOUNDS = [[
if (.outbounds | type) != "array" then error("Config outbounds must be an array") else
    [.outbounds[] |
        if type != "object" then error("Invalid outbound shape")
        elif ((.tag == null or (.tag | type) == "string") and (.type | type) == "string" and .type != ""
            and (.server == null or (.server | type) == "string")
            and (.tls == null or (.tls | type) == "object")
            and (.tls.enabled == null or (.tls.enabled | type) == "boolean")
            and (.tls.fragment == null or (.tls.fragment | type) == "boolean")
            and (.tls.record_fragment == null or (.tls.record_fragment | type) == "boolean")) then
            {tag: (.tag // ""), type, server: (.server // ""), tls_enabled: (.tls.enabled // false),
                has_fragment: ((.tls.fragment // false) or (.tls.record_fragment // false))}
        else error("Invalid outbound shape") end
    ] as $rows | {outbound_count: ($rows | length), outbounds: $rows}
end
]]

local function json_object(raw)
    if type(raw) ~= "string" or not raw:match("^%s*{") then return nil end
    local ok, value = pcall(require("luci.jsonc").parse, raw)
    if ok and type(value) == "table" then return value end
end

-- jq sees only a private immutable snapshot, never the live configuration path.
-- Slurp plus the root guard rejects concatenated JSON documents natively too.
local function query_config(expression, args, error_message)
    local source, read_err = SRV.read_file(SRV.SINGBOX_CONFIG, M.CONFIG_MAX_SIZE)
    if not source then return nil, { success = false, error = "Cannot read config", details = read_err } end
    if not json_object(source) then
        return nil, { success = false, error = "Config must contain exactly one JSON object" }
    end
    local stage, stage_err = SRV.stage_file(SRV.SINGBOX_CONFIG, source, { suffix = ".tmp-read", mode = "600" })
    if not stage then return nil, { success = false, error = "Cannot stage config snapshot", details = stage_err } end
    local command = "jq -c -e -s" .. (args or "") .. " " .. LIB.shell_escape(JQ_OBJECT .. " | " .. expression) ..
        " " .. LIB.shell_escape(stage)
    local ran, ok, output = pcall(SRV.exec_checked, command)
    local cleaned, cleanup_err = SRV.discard_stage(stage)
    if not cleaned then
        local query_failed = not ran or not ok
        local details = query_failed and (ran and output or tostring(ok)) or nil
        local cleanup = "Cannot remove owned config snapshot " .. stage .. ": " .. tostring(cleanup_err or "Cleanup failed")
        return nil, { success = false, error = query_failed and error_message or "Cannot clean up config snapshot",
            details = details and (details .. "\n" .. cleanup) or cleanup, cleanup_failed = true }
    end
    if not ran then return nil, { success = false, error = error_message, details = tostring(ok) } end
    if not ok then return nil, { success = false, error = error_message, details = output } end
    return output, source
end

function M.outbounds()
    local raw, source_or_error = query_config(JQ_OUTBOUNDS, nil, "Cannot enumerate outbounds")
    if not raw then return source_or_error end
    local result = #raw <= M.CONFIG_MAX_SIZE * 8 and json_object(raw) or nil
    local count = result and result.outbound_count
    local rows = result and result.outbounds
    if result and result.error == nil and (result.success == nil or result.success == true) and type(count) == "number" and count >= 0 and count == math.floor(count)
        and count <= M.CONFIG_MAX_SIZE and type(rows) == "table" then
        local actual = 0
        for key, row in pairs(rows) do
            if type(key) ~= "number" or key < 1 or key > count or key ~= math.floor(key) or type(row) ~= "table"
                or row.error ~= nil or type(row.tag) ~= "string" or type(row.type) ~= "string" or row.type == "" or type(row.server) ~= "string"
                or type(row.tls_enabled) ~= "boolean" or type(row.has_fragment) ~= "boolean"
                or row.tls_enabled and not row.tag:match("^[a-zA-Z0-9_%-%.]+$") then
                return { success = false, error = "Invalid outbounds response" }
            end
            actual = actual + 1
        end
        if actual == count then return { outbound_count = count, outbounds = rows } end
    end
    return { success = false, error = "Invalid outbounds response" }
end

function M.patch_fragment(tags_raw, mode_raw, use_fragment_raw, use_record_fragment_raw, fallback_delay_raw)
    local json = require("luci.jsonc")

    local tags = json.parse(tags_raw or "[]")
    if not tags or type(tags) ~= "table" or #tags == 0 then
        return { error = "No outbounds selected" }
    end
    for _, t in ipairs(tags) do
        if type(t) ~= "string" or not t:match("^[a-zA-Z0-9_%-%.]+$") then
            return { error = "Invalid tag value" }
        end
    end
    local mode = mode_raw or "apply"
    local jq_args = ""
    local jq_select = ""
    for i, t in ipairs(tags) do
        jq_args = jq_args .. ' --arg t' .. i .. ' ' .. LIB.shell_escape(t)
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
    local function patch_locked()
        local expression = 'if (.outbounds | type) != "array" then error("Config outbounds must be an array") else ' .. jq_expr .. ' end'
        local patched, source_or_error = query_config(expression, jq_args, "jq patch failed")
        if not patched then return source_or_error end
        if not json_object(patched) then return { success = false, error = "jq patch failed", details = "Expected one JSON object" } end
        local current, read_err = SRV.read_file(SRV.SINGBOX_CONFIG, M.CONFIG_MAX_SIZE)
        if current ~= source_or_error then
            return { success = false, error = current and "Config changed during patch" or "Cannot re-read config", details = read_err }
        end
        local result = SRV.apply_service(SRV.singbox, patched)
        if result.error == "sing-box check failed" then result.error = "sing-box check failed after patch" end
        return result
    end
    local outcome
    local resp, lock_err, uncertain = SRV.with_lock("singbox", function()
        outcome = patch_locked()
        return outcome
    end)
    if not resp then
        local failure = outcome or {}
        if failure.error then failure.details = failure.error .. (failure.details and ("\n" .. failure.details) or "") end
        failure.success, failure.error, failure.unknown = false, lock_err, uncertain or nil
        return failure
    end
    return resp
end

function M.wrapper_status()
    local original, original_err, original_errno = SRV.read_file("/etc/init.d/podkop.orig", LIB.UCI_MAX_SIZE)
    if not original and original_errno ~= 2 then return { error = "Cannot read wrapper original", details = original_err } end
    local installed = original ~= nil
    local function count_hooks(content)
        local counts = { start_service = { detached = 0, legacy = 0 }, reload_service = { detached = 0, legacy = 0 } }
        local managed
        for line in (content or ""):gmatch("[^\r\n]+") do
            if line:match("^[A-Za-z_][A-Za-z_0-9]*%s*%(%)") then
                managed = line:match("^(start_service)%(%)") or line:match("^(reload_service)%(%)")
            end
            if managed then
                local body = line:match("^%s*(.-)%s*$")
                if body == "( sleep 5 && /usr/bin/podkop-fragment-patch.sh ) &" then
                    counts[managed].legacy = counts[managed].legacy + 1
                elseif body == "( sleep 5 && /usr/bin/podkop-fragment-patch.sh ) </dev/null >/dev/null 2>&1 &" then
                    counts[managed].detached = counts[managed].detached + 1
                end
            end
            if line:match("^}") then managed = nil end
        end
        return counts
    end
    local stale, hooks = false, count_hooks()
    if installed then
        local content, init_err, init_errno = SRV.read_file("/etc/init.d/podkop", LIB.UCI_MAX_SIZE)
        if not content and init_errno ~= 2 then return { error = "Cannot read current Podkop init", details = init_err } end
        hooks = count_hooks(content)
        stale = hooks.start_service.detached == 0 or hooks.reload_service.detached == 0 or
            hooks.start_service.legacy > 0 or hooks.reload_service.legacy > 0
    end
    local response = {
        installed = installed,
        stale = stale
    }
    local original_hooks = count_hooks(original)
    for _, name in ipairs({ "start_service", "reload_service" }) do
        if hooks[name].detached + hooks[name].legacy > 1 or
            original_hooks[name].detached + original_hooks[name].legacy > 0 then response.duplicate_hooks = true end
    end
    return response
end

local FRAGMENT_CONFIG = "/etc/config/podkop-fragment"

-- A missing package is a first-use case. An existing package needs both a
-- complete bounded file read and a successful native whole-package UCI parse:
-- get(option) alone cannot tell a missing option from a failed RPC read.
local function read_fragment_config(uci)
    local raw, read_err, errno = SRV.read_file(FRAGMENT_CONFIG, LIB.UCI_MAX_SIZE)
    if not raw then
        if errno == 2 then return {}, nil, true end
        return nil, read_err or "Cannot read Fragment configuration"
    end
    if not raw:match("%S") then return nil, "Fragment configuration is empty" end
    local ran, sections, err = pcall(function()
        uci = uci or require("luci.model.uci").cursor()
        return uci:get_all("podkop-fragment")
    end)
    if not ran then return nil, tostring(sections) end
    if err ~= nil or type(sections) ~= "table" then return nil, err or "Cannot parse Fragment configuration" end
    for name, section in pairs(sections) do
        if type(name) ~= "string" or type(section) ~= "table" or section[".name"] ~= name or
            type(section[".type"]) ~= "string" or section[".type"] == "" then
            return nil, "Invalid Fragment configuration response"
        end
    end
    if sections.settings and sections.settings[".type"] ~= "fragment" then return nil, "Invalid Fragment settings section" end
    return sections, nil, false
end

local function typed_fragment_settings(sections, missing)
    local section = sections.settings or {}
    local fragment, record_fragment, fallback_delay = section.fragment, section.record_fragment, section.fragment_fallback_delay
    if fragment == nil then fragment = "false" end
    if record_fragment == nil then record_fragment = "true" end
    if fallback_delay == nil then fallback_delay = "500ms" end
    if fragment ~= "true" and fragment ~= "false" then return nil, "Invalid Fragment setting: fragment" end
    if record_fragment ~= "true" and record_fragment ~= "false" then return nil, "Invalid Fragment setting: record_fragment" end
    if type(fallback_delay) ~= "string" or not fallback_delay:match("^%d+[a-zA-Z]+$") then
        return nil, "Invalid Fragment setting: fragment_fallback_delay"
    end
    return { fragment = fragment == "true", record_fragment = record_fragment == "true", fallback_delay = fallback_delay,
        settings_source = sections.settings and "uci" or "defaults", config_missing = missing == true }
end

function M.wrapper_toggle(action, fragment_raw, record_fragment_raw, fallback_delay_raw)
    if action ~= "enable" and action ~= "disable" and action ~= "reinstall" then
        return { error = "Invalid action" }
    end
    if action == "enable" then
        local uci = require("luci.model.uci").cursor()
        local sections, read_err = read_fragment_config(uci)
        if not sections then return { success = false, error = "Cannot read Fragment settings", details = read_err } end
        local fragment = fragment_raw == "1"
        local record_fragment = record_fragment_raw == "1"
        local fallback_delay = fallback_delay_raw or "500ms"
        if not fallback_delay:match("^%d+%a+$") then
            fallback_delay = "500ms"
        end
        local function checked_uci(method, ...)
            local ran, ok, err = pcall(uci[method], uci, ...)
            if ran and ok then return true end
            return false, tostring(ran and (err or "UCI operation failed") or ok)
        end
        if not sections.settings then
            local ok, err = checked_uci("set", "podkop-fragment", "settings", "fragment")
            if not ok then return { success = false, error = "Cannot create Fragment settings", details = err } end
        end
        for _, entry in ipairs({
            { "fragment", fragment and "true" or "false" },
            { "record_fragment", record_fragment and "true" or "false" },
            { "fragment_fallback_delay", fallback_delay }
        }) do
            local ok, err = checked_uci("set", "podkop-fragment", "settings", entry[1], entry[2])
            if not ok then return { success = false, error = "Cannot save Fragment setting: " .. entry[1], details = err } end
        end
        local ok, err = checked_uci("commit", "podkop-fragment")
        if not ok then return { success = false, error = "Cannot commit Fragment settings", details = err } end
    end
    local settings_saved = action == "enable"
    if action == "reinstall" then action = "enable" end
    local ok, details, _, outcome = SRV.exec_checked("/etc/init.d/podkop-fragment " .. action)
    if not ok then
        local err_msg = (details or ""):match("^%s*(.-)%s*$")
        if err_msg == "" then err_msg = "Wrapper command failed" end
        return { success = false, error = err_msg, details = details, settings_saved = settings_saved or nil,
            unknown = outcome and outcome.unknown or nil }
    end
    local original, read_err, errno = SRV.read_file("/etc/init.d/podkop.orig", LIB.UCI_MAX_SIZE)
    if not original and errno ~= 2 then
        return { success = false, error = "Cannot read wrapper state", details = read_err, settings_saved = settings_saved or nil }
    end
    local installed = original ~= nil
    if installed ~= (action == "enable") then
        return { success = false, error = "Wrapper state did not change as requested", installed = installed, settings_saved = settings_saved or nil }
    end
    return { success = true, installed = installed }
end

function M.fragment_settings()
    local sections, read_err, missing = read_fragment_config()
    if not sections then return { success = false, error = "Cannot read Fragment settings", details = read_err } end
    local settings, settings_err = typed_fragment_settings(sections, missing)
    if not settings then return { success = false, error = settings_err } end
    return settings
end

return M
