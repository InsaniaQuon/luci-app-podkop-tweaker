-- Author: InsaniaQuon
-- Podkop Tweaker | v3.5.0 | 11.06.2026 | Sing-box tab, fragment patch UI, start/stop, autostart

local APP_VERSION = "3.5.0"

local GIT_REPO = "InsaniaQuon/luci-app-podkop-tweaker"
local GIT_API_URL = "https://api.github.com/repos/" .. GIT_REPO .. "/releases/latest"
local CHECK_CACHE_FILE = "/tmp/tweaker_check_cache.json"
local CHECK_CACHE_TTL = 900
local SUBS_FILE = "/etc/config/podkop-tweaker-subs.json"
local UPDATE_LOG_FILE = "/etc/config/pt-update.log"
local UPDATE_LOG_MAX = 25

local S = require("pt-subs-lib")

local function generate_random_password(length)
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    math.randomseed(os.time(), os.clock())
    local password = {}
    for i = 1, length do
        password[i] = chars:sub(math.random(1, #chars), math.random(1, #chars))
    end
    return table.concat(password)
end

local function set_no_cache_headers()
    local http = require("luci.http")
    http.header("Cache-Control", "no-cache, no-store, must-revalidate")
    http.header("Pragma", "no-cache")
    http.header("Expires", "0")
end

local function sanitize_section_name(name)
    if not name or name == "" then return nil end
    if not name:match("^[a-zA-Z0-9_%-]+$") then return nil end
    return name
end

module("luci.controller.podkop-tweaker", package.seeall)

function index()
    entry({"admin", "services", "podkop-tweaker"},
        alias("admin", "services", "podkop-tweaker", "config"),
        _("Podkop Tweaker"), 60)

    entry({"admin", "services", "podkop-tweaker", "config"},
        call("action_config"), nil, 10)

    entry({"admin", "services", "podkop-tweaker", "stubby"},
        call("action_stubby"), nil, 15)

    entry({"admin", "services", "podkop-tweaker", "singbox"},
        call("action_singbox"), nil, 16)

    entry({"admin", "services", "podkop-tweaker", "diagnostics"},
        call("action_diagnostics"), nil, 17)

    entry({"admin", "services", "podkop-tweaker", "import-export"},
        call("action_import_export"), nil, 20)

    entry({"admin", "services", "podkop-tweaker", "system-info"},
        call("action_system_info"), nil, 30)

    entry({"admin", "services", "podkop-tweaker", "subscriptions"},
        call("action_subscriptions"), nil, 40)

    entry({"admin", "services", "podkop-tweaker", "update"},
        call("action_update"), nil, 50)

    entry({"admin", "services", "podkop-tweaker", "about"},
        call("action_about"), nil, 60)

    entry({"admin", "services", "podkop-tweaker", "api", "read_config"},
        call("api_read_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "save_config"},
        call("api_save_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "read_stubby_config"},
        call("api_read_stubby_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "save_stubby_config"},
        call("api_save_stubby_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "stubby_service_status"},
        call("api_stubby_service_status")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "stubby_service_toggle"},
        call("api_stubby_service_toggle")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "rollback_stubby"},
        call("api_rollback_stubby")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "export_stubby_config"},
        call("api_export_stubby_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "download_stubby_backup"},
        call("api_download_stubby_backup")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "stubby_chain_info"},
        call("api_stubby_chain_info")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "stubby_init_check"},
        call("api_stubby_init_check")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "stubby_init_fix"},
        call("api_stubby_init_fix")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "import_stubby_config"},
        call("api_import_stubby_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "apply_recommended_stubby"},
        call("api_apply_recommended_stubby")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "read_singbox_config"},
        call("api_read_singbox_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "save_singbox_config"},
        call("api_save_singbox_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "singbox_service_status"},
        call("api_singbox_service_status")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "singbox_service_toggle"},
        call("api_singbox_service_toggle")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "rollback_singbox"},
        call("api_rollback_singbox")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "export_singbox_config"},
        call("api_export_singbox_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "download_singbox_backup"},
        call("api_download_singbox_backup")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "import_singbox_config"},
        call("api_import_singbox_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "singbox_outbounds"},
        call("api_singbox_outbounds")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "singbox_patch_fragment"},
        call("api_singbox_patch_fragment")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "wrapper_status"},
        call("api_wrapper_status")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "wrapper_toggle"},
        call("api_wrapper_toggle")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "podkop_service_toggle"},
        call("api_podkop_service_toggle")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "podkop_autostart"},
        call("api_podkop_autostart")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "podkop_autostart_toggle"},
        call("api_podkop_autostart_toggle")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "stubby_autostart"},
        call("api_stubby_autostart")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "stubby_autostart_toggle"},
        call("api_stubby_autostart_toggle")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "diag_dns"},
        call("api_diag_dns")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "diag_proxy"},
        call("api_diag_proxy")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "diag_e2e"},
        call("api_diag_e2e")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "diag_dns_leak"},
        call("api_diag_dns_leak")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "export_config"},
        call("api_export_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "import_config"},
        call("api_import_config")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "download_backup"},
        call("api_download_backup")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "service_status"},
        call("api_service_status")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "rollback"},
        call("api_rollback")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "system_info"},
        call("api_system_info")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "update_start"},
        call("api_update_start")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "subscription_state"},
        call("api_subscription_state")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "subscription_fetch"},
        call("api_subscription_fetch")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "subscription_attach"},
        call("api_subscription_attach")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "subscription_detach"},
        call("api_subscription_detach")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "settings_read"},
        call("api_settings_read")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "settings_save"},
        call("api_settings_save")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "update_all_subs"},
        call("api_update_all_subs")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "download_sub_backup"},
        call("api_download_sub_backup")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "upload_update"},
        call("api_upload_update")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "apply_update"},
        call("api_apply_update")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "tweaker_check_update"},
        call("api_tweaker_check_update")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "tweaker_git_update"},
        call("api_tweaker_git_update")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "clear_cache"},
        call("api_clear_cache")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "app_version"},
        call("api_app_version")).leaf = true

    entry({"admin", "services", "podkop-tweaker", "api", "read_update_log"},
        call("api_read_update_log")).leaf = true
end

local function render_page(template_name, extra)
    local disp = require("luci.dispatcher")
    local vars = {
        app_version = APP_VERSION,
        csrf_token = (disp.context and disp.context.token) or ""
    }
    if extra then for k, v in pairs(extra) do vars[k] = v end end
    luci.template.render("podkop-tweaker/" .. template_name, vars)
end

function action_config()
    render_page("config")
end

function action_stubby()
    render_page("stubby")
end

function action_singbox()
    render_page("singbox")
end

function action_diagnostics()
    render_page("diagnostics")
end

function action_import_export()
    local nixio = require("nixio")
    local auto_backup_attr = nixio.fs.stat("/etc/config/podkop.auto-backup")
    local auto_backup_time = auto_backup_attr
        and os.date("%H:%M %d.%m.%Y", auto_backup_attr.mtime) or nil
    local sub_backup_attr = nixio.fs.stat("/etc/config/podkop.sub-backup")
    local auto_sub_backup_time = sub_backup_attr
        and os.date("%H:%M %d.%m.%Y", sub_backup_attr.mtime) or nil
    local stubby_backup_attr = nixio.fs.stat("/etc/config/stubby.auto-backup")
    local stubby_backup_time = stubby_backup_attr
        and os.date("%H:%M %d.%m.%Y", stubby_backup_attr.mtime) or nil
    local singbox_backup_attr = nixio.fs.stat("/etc/sing-box/config.json.auto-backup")
    local singbox_backup_time = singbox_backup_attr
        and os.date("%H:%M %d.%m.%Y", singbox_backup_attr.mtime) or nil
    render_page("import-export", {
        auto_backup_time = auto_backup_time,
        auto_sub_backup_time = auto_sub_backup_time,
        stubby_backup_time = stubby_backup_time,
        singbox_backup_time = singbox_backup_time
    })
end

function action_system_info()
    render_page("system-info")
end

function action_subscriptions()
    render_page("subscriptions")
end

function action_update()
    render_page("update")
end

function action_about()
    render_page("about")
end

local function verify_csrf()
    local http = require("luci.http")
    local disp = require("luci.dispatcher")
    local expected = disp.context and disp.context.token
    if not expected or expected == "" then
        local cookie = http.getenv("HTTP_COOKIE") or ""
        local referer = http.getenv("HTTP_REFERER") or ""
        local server_name = http.getenv("SERVER_NAME") or ""
        local content_type = http.getenv("CONTENT_TYPE") or ""
        local ct_ok = content_type:match("^application/x%-www%-form%-urlencoded")
            or content_type:match("^multipart/form%-data")
        if ct_ok and cookie ~= "" and server_name ~= "" and referer ~= ""
            and referer:match("^https?://" .. server_name:gsub("%-", "%%-") .. "[:/]") then
            return true
        end
        http.prepare_content("application/json")
        http.status(403, "Forbidden")
        http.write_json({ error = "CSRF token not available" })
        return false
    end
    local token = http.formvalue("token")
    if not token or token ~= expected then
        http.prepare_content("application/json")
        http.status(403, "Forbidden")
        http.write_json({ error = "CSRF token mismatch" })
        return false
    end
    return true
end

local function get_service_pid(process_name)
    local sys = require("luci.sys")
    return sys.exec("pidof " .. process_name .. " 2>/dev/null"):match("(%d+)")
end

local function validate_uci_config(content)
    if not content or content == "" then
        return false, "Configuration is empty"
    end
    if #content > 1048576 then
        return false, "Config too large (max 1MB)"
    end
    if not content:match("config%s+") then
        return false, "Invalid UCI format: no 'config' declarations found"
    end
    if content:find("\0", 1, true) then
        return false, "Invalid content: contains null bytes"
    end
    local line_no = 0
    local in_sq = false
    local dq_total = 0
    for line in content:gmatch("[^\r\n]+") do
        line_no = line_no + 1
        if not in_sq then
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed ~= "" and not trimmed:match("^#") then
                if not trimmed:match("^config%s")
                    and not trimmed:match("^option%s")
                    and not trimmed:match("^list%s") then
                    return false, "Invalid UCI syntax at line " .. line_no .. ": unexpected token"
                end
            end
        end
        for ci = 1, #line do
            local b = line:byte(ci)
            if b < 9 or (b > 13 and b < 32) then
                return false, "Invalid character at line " .. line_no .. ", column " .. ci
            end
            local c = line:sub(ci, ci)
            if c == "'" then in_sq = not in_sq
            elseif c == '"' then dq_total = dq_total + 1
            end
        end
    end
    if in_sq then
        return false, "Unmatched single quote"
    end
    if dq_total % 2 ~= 0 then
        return false, "Unmatched double quote"
    end
    return true
end

local function backup_config()
    return S.backup_config()
end

local function save_and_restart(content)
    local sys = require("luci.sys")
    local config_path = "/etc/config/podkop"
    local tmp_path = config_path .. ".tmp-write"

    if not backup_config() then
        return false, "Cannot create backup"
    end

    local tmpfd = io.open(tmp_path, "w")
    if not tmpfd then
        return false, "Cannot write temporary file"
    end
    tmpfd:write(content)
    tmpfd:close()

    local ok, err = os.rename(tmp_path, config_path)
    if not ok then
        return false, "Cannot apply config: " .. (err or "unknown error")
    end

    sys.exec("/etc/init.d/podkop restart 2>&1")
    return true
end

local function parse_version(ver)
    if not ver then return nil end
    ver = ver:gsub("^v", "")
    local major, minor, patch = ver:match("^(%d+)%.(%d+)%.(%d+)")
    if not major then return nil end
    return { tonumber(major), tonumber(minor), tonumber(patch) }
end

local function version_lt(a, b)
    local va = parse_version(a)
    local vb = parse_version(b)
    if not va or not vb then return false end
    for i = 1, 3 do
        if (va[i] or 0) < (vb[i] or 0) then return true end
        if (va[i] or 0) > (vb[i] or 0) then return false end
    end
    return false
end

function api_system_info()
    local sys = require("luci.sys")
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()

    local raw = sys.exec("podkop get_system_info 2>/dev/null")

    local info
    pcall(function() info = luci.json and luci.json.parse and luci.json.parse(raw) end)
    if not info then
        pcall(function()
            local json = require("luci.jsonc")
            info = json.parse(raw)
        end)
    end
    if not info then
        pcall(function()
            local json = require("cjson")
            info = json.decode(raw)
        end)
    end

    if not info or not info.podkop_version then
        http.write_json({
            podkop_version = "unknown",
            podkop_latest_version = "unknown",
            luci_app_version = "unknown",
            sing_box_version = "unknown",
            openwrt_version = "unknown",
            device_model = "unknown",
            update_available = false,
            tweaker_version = APP_VERSION,
            tweaker_latest = nil,
            error = "Failed to get system info from podkop"
        })
        return
    end

    local update_available = false
    if info.podkop_latest_version
        and info.podkop_latest_version ~= "unknown"
        and info.podkop_version ~= "unknown" then
        update_available = version_lt(info.podkop_version, info.podkop_latest_version)
    end

    local tweaker_latest = nil
    local cache_fd = io.open(CHECK_CACHE_FILE, "r")
    if cache_fd then
        local raw_cache = cache_fd:read("*a")
        cache_fd:close()
        local tweaker_cache = nil
        pcall(function()
            local json = require("luci.jsonc")
            tweaker_cache = json.parse(raw_cache)
        end)
        if tweaker_cache and tweaker_cache.latest_version and tweaker_cache.cached_at then
            local elapsed = os.time() - tweaker_cache.cached_at
            if elapsed < CHECK_CACHE_TTL then
                tweaker_latest = tweaker_cache.latest_version
            end
        end
    end

    local stubby_ver = sys.exec("stubby -V 2>/dev/null"):match("Stubby%s+(%S+)") or "not installed"

    http.write_json({
        podkop_version = info.podkop_version or "unknown",
        podkop_latest_version = info.podkop_latest_version or "unknown",
        luci_app_version = info.luci_app_version or "unknown",
        stubby_version = stubby_ver,
        sing_box_version = info.sing_box_version or "unknown",
        openwrt_version = info.openwrt_version or "unknown",
        device_model = info.device_model or "unknown",
        update_available = update_available,
        tweaker_version = APP_VERSION,
        tweaker_latest = tweaker_latest
    })
end

function api_update_start()
    if not verify_csrf() then return end
    local sys = require("luci.sys")
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()

    if not backup_config() then
        http.write_json({ error = "Cannot create backup before update" })
        return
    end

    sys.exec("pkill -f 'ttyd.*podkop-update' 2>/dev/null")

    local host = http.getenv("SERVER_NAME") or "127.0.0.1"
    if not host:match("^[%w%.%-]+:%d+$") and not host:match("^[%w%.%-]+$") then
        host = http.getenv("SERVER_NAME") or "127.0.0.1"
    end
    local port = "7682"

    sys.exec("ttyd -p " .. port .. " podkop-update >/dev/null 2>&1 &")

    http.write_json({ success = true, url = "http://" .. host .. ":" .. port })
end

-- === Subscription helpers ===

-- === Subscription API ===

function api_subscription_state()
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()

    local sections = S.get_proxy_sections()
    local subs = S.read_subs(SUBS_FILE)

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

function api_subscription_fetch()
    if not verify_csrf() then return end
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()

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

function api_subscription_attach()
    if not verify_csrf() then return end
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()

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
        if not sanitize_section_name(section_name) then
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
            local subs = S.read_subs(SUBS_FILE)
            if not subs[section_name] then subs[section_name] = {} end
            while #subs[section_name] < slot_index + 1 do
                table.insert(subs[section_name], false)
            end
            subs[section_name][slot_index + 1] = {
                subscription_url = subscription_url,
                proxy_name = proxy_name,
                last_updated = os.date("%H:%M %d.%m.%Y") .. " (manual)"
            }
            if not S.write_subs(subs, SUBS_FILE) then
                http.write_json({ error = "Failed to save data" })
                return
            end
            local log_text = os.date("%H:%M %d.%m.%Y") .. "|manual|updated=0|unchanged=1|failed=0"
                .. "\n  " .. section_name .. ":\n    " .. proxy_name .. ": unchanged"
            S.append_log(UPDATE_LOG_FILE, UPDATE_LOG_MAX, log_text)
            http.write_json({ success = true, unchanged = true })
            return
        end

        S.write_sub_backup()

        local ok2, err2 = S.replace_proxy_link(section_name, proxy_type, slot_index, new_link)
        if not ok2 then
            http.write_json({ error = err2 })
            return
        end

        local subs = S.read_subs(SUBS_FILE)
        if not subs[section_name] then subs[section_name] = {} end
        while #subs[section_name] < slot_index + 1 do
            table.insert(subs[section_name], false)
        end
        subs[section_name][slot_index + 1] = {
            subscription_url = subscription_url,
            proxy_name = proxy_name,
            last_updated = os.date("%H:%M %d.%m.%Y") .. " (manual)"
        }
        if not S.write_subs(subs, SUBS_FILE) then
            http.write_json({ error = "Failed to save data" })
            return
        end

        sys.exec("nohup /etc/init.d/podkop restart >/dev/null 2>&1 &")
        local log_text = os.date("%H:%M %d.%m.%Y") .. "|manual|updated=1|unchanged=0|failed=0"
            .. "\n  " .. section_name .. ":\n    " .. proxy_name .. ": updated"
        S.append_log(UPDATE_LOG_FILE, UPDATE_LOG_MAX, log_text)
        http.write_json({ success = true, restarting = true })
    end)

    if not ok then
        http.prepare_content("application/json")
        http.write_json({ error = "Internal error" })
    end
end

function api_subscription_detach()
    if not verify_csrf() then return end
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()

    local ok, err = pcall(function()
        local section_name = http.formvalue("section") or ""
        local slot_index = tonumber(http.formvalue("index") or "-1")

        if not slot_index or slot_index < 0 or slot_index > 999 or section_name == "" then
            http.write_json({ error = "Missing required parameters" })
            return
        end
        if not sanitize_section_name(section_name) then
            http.write_json({ error = "Invalid section name" })
            return
        end

        local subs = S.read_subs(SUBS_FILE)
        if subs[section_name] and subs[section_name][slot_index + 1] then
            subs[section_name][slot_index + 1] = nil
            if not S.write_subs(subs, SUBS_FILE) then
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

function api_read_config()
    local http = require("luci.http")
    http.prepare_content("text/plain")
    set_no_cache_headers()
    local fd = io.open("/etc/config/podkop", "r")
    if fd then
        local content = fd:read("*a")
        fd:close()
        http.write(content)
    else
        http.write("")
    end
end

function api_save_config()
    if not verify_csrf() then return end
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local content = http.formvalue("content") or ""
    local ok, err = validate_uci_config(content)
    if not ok then
        http.write_json({ error = err })
        return
    end
    ok, err = save_and_restart(content)
    if not ok then
        http.write_json({ error = err })
        return
    end
    http.write_json({ success = true, restarting = true })
end

function api_export_config()
    local http = require("luci.http")
    local nixio = require("nixio")
    local config_path = "/etc/config/podkop"
    if not nixio.fs.stat(config_path) then
        http.status(404, "Config not found")
        return
    end
    http.prepare_content("application/octet-stream")
    set_no_cache_headers()
    http.header("Content-Disposition", 'attachment; filename="podkop-config-export.conf"')
    local fd = io.open(config_path, "r")
    if fd then
        local content = fd:read("*a")
        fd:close()
        http.write(content)
    else
        http.status(500, "Cannot read config")
    end
end

function api_download_backup()
    local http = require("luci.http")
    local nixio = require("nixio")
    local backup_path = "/etc/config/podkop.auto-backup"
    if not nixio.fs.stat(backup_path) then
        http.prepare_content("application/json")
        http.write_json({ error = "Backup file not found" })
        return
    end
    http.prepare_content("application/octet-stream")
    set_no_cache_headers()
    http.header("Content-Disposition", 'attachment; filename="podkop-auto-backup.conf"')
    local fd = io.open(backup_path, "r")
    if fd then
        local content = fd:read("*a")
        fd:close()
        http.write(content)
    else
        http.status(500, "Cannot read backup")
    end
end

function api_import_config()
    if not verify_csrf() then return end
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local upload_content = http.formvalue("content") or ""
    if upload_content == "" then
        local fdupload = http.formvalue("file")
        if type(fdupload) == "table" and fdupload.data then
            upload_content = fdupload.data
        elseif type(fdupload) == "string" then
            upload_content = fdupload
        end
    end
    local ok, err = validate_uci_config(upload_content)
    if not ok then
        http.write_json({ error = err })
        return
    end
    ok, err = save_and_restart(upload_content)
    if not ok then
        http.write_json({ error = err })
        return
    end
    http.write_json({ success = true, restarting = true })
end

function api_service_status()
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local pid = get_service_pid("sing-box")
    http.write_json({
        running = (pid ~= nil)
    })
end

function api_rollback()
    if not verify_csrf() then return end
    local http = require("luci.http")
    local nixio = require("nixio")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local config_path = "/etc/config/podkop"
    local backup_path = "/etc/config/podkop.auto-backup"
    if not nixio.fs.stat(backup_path) then
        http.write_json({ error = "Backup file not found" })
        return
    end
    local data = nixio.fs.readfile(backup_path)
    if not data then
        http.write_json({ error = "Cannot read backup" })
        return
    end
    local fd = io.open(config_path, "w")
    if not fd then
        http.write_json({ error = "Cannot write config" })
        return
    end
    fd:write(data)
    fd:close()
    sys.exec("/etc/init.d/podkop restart 2>&1")
    http.write_json({ success = true, restarting = true })
end

-- === Stubby Config ===

function api_read_stubby_config()
    local http = require("luci.http")
    http.prepare_content("text/plain")
    set_no_cache_headers()
    local fd = io.open("/etc/config/stubby", "r")
    if fd then
        local content = fd:read("*a")
        fd:close()
        http.write(content)
    else
        http.write("")
    end
end

function api_save_stubby_config()
    if not verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local content = http.formvalue("content") or ""
    local ok, err = validate_uci_config(content)
    if not ok then
        http.write_json({ error = err })
        return
    end
    local config_path = "/etc/config/stubby"
    local backup_path = "/etc/config/stubby.auto-backup"
    local rfd = io.open(config_path, "r")
    if rfd then
        local orig = rfd:read("*a")
        rfd:close()
        if orig == content then
            http.write_json({ success = true, unchanged = true })
            return
        end
        local bfd = io.open(backup_path, "w")
        if bfd then
            bfd:write(orig)
            bfd:close()
        end
    end
    local tmp_path = config_path .. ".tmp-write"
    local tmpfd = io.open(tmp_path, "w")
    if not tmpfd then
        http.write_json({ error = "Cannot write temporary file" })
        return
    end
    tmpfd:write(content)
    tmpfd:close()
    os.rename(tmp_path, config_path)
    sys.exec("/etc/init.d/stubby restart 2>&1")
    http.write_json({ success = true, restarting = true })
end

function api_stubby_service_status()
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local pid = get_service_pid("stubby")
    http.write_json({
        running = (pid ~= nil)
    })
end

function api_stubby_service_toggle()
    if not verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local action = http.formvalue("action") or ""
    if action ~= "start" and action ~= "stop" then
        http.write_json({ error = "Invalid action" })
        return
    end
    sys.exec("/etc/init.d/stubby " .. action .. " 2>&1")
    local pid = get_service_pid("stubby")
    http.write_json({
        success = true,
        running = (pid ~= nil)
    })
end

function api_rollback_stubby()
    if not verify_csrf() then return end
    local http = require("luci.http")
    local nixio = require("nixio")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local config_path = "/etc/config/stubby"
    local backup_path = "/etc/config/stubby.auto-backup"
    if not nixio.fs.stat(backup_path) then
        http.write_json({ error = "Backup file not found" })
        return
    end
    local data = nixio.fs.readfile(backup_path)
    if not data then
        http.write_json({ error = "Cannot read backup" })
        return
    end
    local fd = io.open(config_path, "w")
    if not fd then
        http.write_json({ error = "Cannot write config" })
        return
    end
    fd:write(data)
    fd:close()
    sys.exec("/etc/init.d/stubby restart 2>&1")
    http.write_json({ success = true, restarting = true })
end

function api_export_stubby_config()
    local http = require("luci.http")
    http.prepare_content("text/plain")
    set_no_cache_headers()
    http.header("Content-Disposition", 'attachment; filename="stubby-config.txt"')
    local fd = io.open("/etc/config/stubby", "r")
    if fd then
        local content = fd:read("*a")
        fd:close()
        http.write(content)
    else
        http.status(404, "Not Found")
        http.write("")
    end
end

function api_download_stubby_backup()
    local http = require("luci.http")
    local nixio = require("nixio")
    http.prepare_content("text/plain")
    set_no_cache_headers()
    local backup_path = "/etc/config/stubby.auto-backup"
    if not nixio.fs.stat(backup_path) then
        http.status(404, "Not Found")
        http.write_json({ error = "No stubby backup found" })
        return
    end
    http.header("Content-Disposition", 'attachment; filename="stubby-backup.txt"')
    local data = nixio.fs.readfile(backup_path)
    if data then
        http.write(data)
    else
        http.write("")
    end
end

function api_stubby_chain_info()
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()

    local uci = require("luci.model.uci").cursor()

    local stubby_listen = ""
    uci:foreach("stubby", "stubby", function(s)
        if s[".name"] == "global" then
            local la = uci:get("stubby", "global", "listen_address")
            if type(la) == "table" then
                stubby_listen = table.concat(la, ", ")
            elseif type(la) == "string" then
                stubby_listen = la
            end
        end
    end)

    local resolvers = {}
    uci:foreach("stubby", "resolver", function(s)
        table.insert(resolvers, {
            address = s.address or "",
            tls_auth_name = s.tls_auth_name or "",
            tls_port = s.tls_port or "853"
        })
    end)

    local podkop_dns = ""
    uci:foreach("podkop", "section", function(s)
        if s.dns_server then
            podkop_dns = s.dns_server
        end
    end)

    http.write_json({
        stubby_listen = stubby_listen,
        resolvers = resolvers,
        podkop_dns = podkop_dns
    })
end

function api_stubby_init_check()
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()

    local fd = io.open("/etc/init.d/stubby", "r")
    if not fd then
        http.write_json({ status = "not_installed" })
        return
    end
    local content = fd:read("*a")
    fd:close()

    if content:match("procd_set_param user stubby") then
        http.write_json({ status = "needs_fix" })
    else
        http.write_json({ status = "fixed" })
    end
end

function api_stubby_init_fix()
    if not verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    set_no_cache_headers()

    local fd = io.open("/etc/init.d/stubby", "r")
    if not fd then
        http.write_json({ error = "Init script not found" })
        return
    end
    local content = fd:read("*a")
    fd:close()

    if not content:match("procd_set_param user stubby") then
        http.write_json({ success = true, message = "Already fixed" })
        return
    end

    content = content:gsub("procd_set_param user stubby", "procd_set_param user root")
    local tmp_path = "/etc/init.d/stubby.tmp-fix"
    local tmpfd = io.open(tmp_path, "w")
    if not tmpfd then
        http.write_json({ error = "Cannot write init script" })
        return
    end
    tmpfd:write(content)
    tmpfd:close()
    sys.exec("chmod +x " .. tmp_path .. " && mv " .. tmp_path .. " /etc/init.d/stubby 2>/dev/null")
    sys.exec("/etc/init.d/stubby restart 2>&1")

    http.write_json({ success = true })
end

function api_import_stubby_config()
    if not verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local content = http.formvalue("content") or ""
    if content == "" then
        http.write_json({ error = "Empty content" })
        return
    end
    local ok, err = validate_uci_config(content)
    if not ok then
        http.write_json({ error = err })
        return
    end
    if not S.backup_stubby_config() then
        http.write_json({ error = "Cannot create backup" })
        return
    end
    local config_path = "/etc/config/stubby"
    local tmp_path = config_path .. ".tmp-write"
    local tmpfd = io.open(tmp_path, "w")
    if not tmpfd then
        http.write_json({ error = "Cannot write config" })
        return
    end
    tmpfd:write(content)
    tmpfd:close()
    os.rename(tmp_path, config_path)
    sys.exec("/etc/init.d/stubby restart 2>&1")
    http.write_json({ success = true, restarting = true })
end

local STUBBY_RECOMMENDED = [[
config stubby 'global'
	option manual '0'
	option trigger 'wan'
	option triggerdelay '5'
	list dns_transport 'GETDNS_TRANSPORT_TLS'
	option tls_authentication '1'
	option tls_query_padding_blocksize '128'
	option tls_min_version '1.3'
	option tls_ciphersuites 'TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256'
	option tls_connection_retries '2'
	option tls_backoff_time '3600'
	option timeout '5000'
	option idle_timeout '30000'
	option round_robin_upstreams '1'
	option dnssec_return_status '0'
	option edns_client_subnet_private '1'
	list listen_address '127.0.0.53@53'

config resolver
	option address '1.1.1.1'
	option tls_auth_name 'cloudflare-dns.com'
	option tls_port '853'

config resolver
	option address '1.0.0.1'
	option tls_auth_name 'cloudflare-dns.com'
	option tls_port '853'

config resolver
	option address '9.9.9.9'
	option tls_auth_name 'dns.quad9.net'
	option tls_port '853'

config resolver
	option address '149.112.112.112'
	option tls_auth_name 'dns.quad9.net'
	option tls_port '853'
]]

function api_apply_recommended_stubby()
    if not verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    set_no_cache_headers()
    if not S.backup_stubby_config() then
        http.write_json({ error = "Cannot create backup" })
        return
    end
    local config_path = "/etc/config/stubby"
    local tmp_path = config_path .. ".tmp-write"
    local tmpfd = io.open(tmp_path, "w")
    if not tmpfd then
        http.write_json({ error = "Cannot write config" })
        return
    end
    tmpfd:write(STUBBY_RECOMMENDED)
    tmpfd:close()
    os.rename(tmp_path, config_path)
    sys.exec("/etc/init.d/stubby restart 2>&1")
    http.write_json({ success = true, restarting = true })
end

-- === Settings & Auto-Update ===

-- interval: hours between updates (1-24)
-- start_time: "HH:MM" in MSK, the first run time
-- generates cron hours: start_hour, start_hour+interval, start_hour+2*interval, ... while <= 23
-- examples:
--   interval=4, start="02:00" -> 2,6,10,14,18,22 -> "0 2,6,10,14,18,22 * * *"
--   interval=8, start="03:00" -> 3,11,19          -> "0 3,11,19 * * *"
--   interval=24, start="04:00" -> 4               -> "0 4 * * *"
local function setup_cron(interval, start_time)
    local sys = require("luci.sys")
    sys.exec("(crontab -l 2>/dev/null | grep -v pt-auto-update; true) | crontab -")
    if not interval or interval <= 0 or not start_time or start_time == "" then return end

    local hh, mm = start_time:match("^(%d+):(%d+)$")
    if not hh or not mm then return end
    hh, mm = tonumber(hh), tonumber(mm)
    if not hh or hh > 23 or not mm or mm > 59 then return end
    if interval < 1 then interval = 1 end
    if interval > 24 then interval = 24 end

    local hours = {}
    local h = hh
    while h <= 23 do
        table.insert(hours, tostring(h))
        h = h + interval
    end

    local cron_hours = table.concat(hours, ",")
    sys.exec("(crontab -l 2>/dev/null; echo '" .. mm .. " " .. cron_hours .. " * * * /usr/bin/pt-auto-update') | crontab -")
end

local function setup_hotplug(enabled)
    local hp_path = "/etc/hotplug.d/iface/99-pt-subs"
    if enabled then
        os.execute("mkdir -p /etc/hotplug.d/iface 2>/dev/null")
        local fd = io.open(hp_path, "w")
        if fd then
            fd:write("#!/bin/sh\n")
            fd:write('[ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "wan" ] && (sleep 30; /usr/bin/pt-auto-update) >/dev/null 2>&1 &\n')
            fd:close()
            os.execute("chmod +x " .. hp_path .. " 2>/dev/null")
        end
    else
        os.execute("rm -f " .. hp_path .. " 2>/dev/null")
    end
end

local function create_auto_update_script()
    local script_path = "/usr/bin/pt-auto-update"
    local fd = io.open(script_path, "w")
    if not fd then return false end
    fd:write("#!/bin/sh\n")
    fd:write("lua /usr/lib/lua/pt-auto-update.lua\n")
    fd:close()
    os.execute("chmod +x " .. script_path .. " 2>/dev/null")
    return true
end

function api_settings_read()
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()

    local subs = S.read_subs(SUBS_FILE)
    local settings = subs.settings or {}

    http.write_json({
        auto_update_interval = settings.auto_update_interval or 0,
        auto_update_start = settings.auto_update_start or "",
        auto_update_on_restart = settings.auto_update_on_restart or false,
        log_display_count = settings.log_display_count or 10
    })
end

function api_settings_save()
    if not verify_csrf() then return end
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()

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

        local subs = S.read_subs(SUBS_FILE)
        subs.settings = {
            auto_update_interval = interval,
            auto_update_start = start_time,
            auto_update_on_restart = on_restart,
            log_display_count = log_display
        }
        if not S.write_subs(subs, SUBS_FILE) then
            http.write_json({ error = "Failed to save settings" })
            return
        end

        create_auto_update_script()

        setup_cron(interval, start_time)
        setup_hotplug(on_restart)

        http.write_json({ success = true })
    end)

    if not ok then
        http.prepare_content("application/json")
        http.write_json({ error = "Internal error" })
    end
end

function api_update_all_subs()
    if not verify_csrf() then return end
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()

    local ok, err = pcall(function()
        local sys = require("luci.sys")
        local result = S.update_all_subscriptions(SUBS_FILE, UPDATE_LOG_FILE, UPDATE_LOG_MAX, "manual")

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

function api_download_sub_backup()
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

-- === Update Tweaker ===

local function extract_version_from_file(dir_prefix)
    local ctrl_path = dir_prefix .. "/usr/lib/lua/luci/controller/podkop-tweaker.lua"
    local fd = io.open(ctrl_path, "r")
    if not fd then return nil end
    local ver = nil
    for line in fd:lines() do
        ver = line:match('APP_VERSION%s*=%s*"([^"]+)"')
        if ver then break end
    end
    fd:close()
    return ver
end

local function validate_archive_structure(dir_prefix, relaxed)
    local sys = require("luci.sys")
    local find_cmd = "find '" .. dir_prefix .. "' -type f \\! -type l 2>/dev/null"
    local raw = sys.exec(find_cmd)
    if not raw or raw == "" then return false, "Archive is empty" end

    local prefix_len = #dir_prefix + 1
    local count = 0
    for line in raw:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then
            local rel = line:sub(prefix_len):match("^/?(.*)")
            if rel ~= "" then
                count = count + 1
                if not S._is_valid_update_path(rel, relaxed) then
                    return false, "file not allowed"
                end
            end
        end
    end

    if count == 0 then return false, "No files found in archive" end

    local ctrl_rel = "usr/lib/lua/luci/controller/podkop-tweaker.lua"
    local ctrl_full = dir_prefix .. "/" .. ctrl_rel
    local st = io.open(ctrl_full, "r")
    if not st then return false, "Controller file not found in archive" end
    st:close()

    return true, count .. " file(s) validated"
end

function api_upload_update()
    if not verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    set_no_cache_headers()

    local ok, err = pcall(function()
        local file_data_b64 = http.formvalue("file_data") or ""
        local file_name = http.formvalue("file_name") or ""

        if file_data_b64 == "" then
            http.write_json({ error = "No file uploaded" })
            return
        end

        local file_data = S.b64decode(file_data_b64)
        if not file_data or file_data == "" then
            http.write_json({ error = "Invalid archive" })
            return
        end

        if #file_data > 128000 then
            http.write_json({ error = "Invalid archive" })
            return
        end

        if not file_name:match("luci%-app%-podkop%-tweaker%-v.+%.tar%.gz$") then
            http.write_json({ error = "Invalid archive" })
            return
        end

        local tmp_dir = "/tmp/pt-update"
        sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
        sys.exec("mkdir -p " .. tmp_dir .. " 2>/dev/null")

        local archive_path = tmp_dir .. "/upload.tar.gz"
        local fd = io.open(archive_path, "wb")
        if not fd then
            http.write_json({ error = "Invalid archive" })
            return
        end
        fd:write(file_data)
        fd:close()

        sys.exec("cd " .. tmp_dir .. " && tar -xzf upload.tar.gz 2>&1")
        sys.exec("rm -f " .. archive_path .. " 2>/dev/null")

        local extract_dir = tmp_dir
        local stat = io.open(extract_dir .. "/usr/lib/lua/luci/controller/podkop-tweaker.lua", "r")
        if not stat then
            http.write_json({ error = "Invalid archive" })
            sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
            return
        end
        stat:close()

        local valid, verr = validate_archive_structure(extract_dir, false)
        if not valid then
            http.write_json({ error = "Invalid archive" })
            sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
            return
        end

        local archive_ver = extract_version_from_file(extract_dir)
        if not archive_ver then
            http.write_json({ error = "Invalid archive" })
            sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
            return
        end

        local can_update = version_lt(APP_VERSION, archive_ver)
        local same_version = not version_lt(APP_VERSION, archive_ver)
            and not version_lt(archive_ver, APP_VERSION)

        http.write_json({
            success = true,
            current_version = APP_VERSION,
            archive_version = archive_ver,
            can_update = can_update,
            same_version = same_version
        })
    end)

    if not ok then
        http.prepare_content("application/json")
        http.write_json({ error = "Internal error" })
    end
end

function api_apply_update()
    if not verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    local nixio = require("nixio")
    http.prepare_content("application/json")
    set_no_cache_headers()

    local ok, err = pcall(function()
        local tmp_dir = "/tmp/pt-update"
        local extract_dir = tmp_dir

        if not nixio.fs.stat(extract_dir) then
            http.write_json({ error = "No archive uploaded" })
            return
        end

        local archive_ver = extract_version_from_file(extract_dir)
        if not archive_ver then
            http.write_json({ error = "Invalid archive" })
            sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
            return
        end

        if not version_lt(APP_VERSION, archive_ver) then
            http.write_json({ error = "Archive version is not newer than installed" })
            return
        end

        local copied = S.apply_files_from_dir(extract_dir, false)

        sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
        sys.exec("rm -rf /tmp/luci-modulecache 2>/dev/null")
        sys.exec("nohup /etc/init.d/uhttpd restart >/dev/null 2>&1 &")

        http.write_json({
            success = true,
            new_version = archive_ver,
            files_copied = copied
        })
    end)

    if not ok then
        http.prepare_content("application/json")
        http.write_json({ error = "Internal error" })
    end
end

function api_clear_cache()
    if not verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    set_no_cache_headers()

    os.execute("rm -rf /tmp/luci-* 2>/dev/null")
    os.remove(CHECK_CACHE_FILE)

    sys.exec("nohup /etc/init.d/uhttpd restart >/dev/null 2>&1 &")

    http.write_json({ success = true })
end

function api_app_version()
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()
    http.write_json({ version = APP_VERSION })
end

function api_read_update_log()
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()

    local lines = {}
    local n = 0
    local fd = io.open(UPDATE_LOG_FILE, "r")
    if fd then
        for line in fd:lines() do
            n = n + 1
            lines[n] = line
        end
        fd:close()
    end

    local json = require("luci.jsonc")
    local resp = '{"lines":['
    for i = 1, n do
        if i > 1 then resp = resp .. ',' end
        resp = resp .. json.stringify(lines[i])
    end
    resp = resp .. ']}'
    http.write(resp)
end

-- === Git Update (GitHub Releases API) ===

function api_tweaker_check_update()
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    set_no_cache_headers()

    local cache_fd = io.open(CHECK_CACHE_FILE, "r")
    if cache_fd then
        local cache_data = cache_fd:read("*a")
        cache_fd:close()
        local cache = S.json_parse(cache_data)
        if cache and cache.cached_at then
            local elapsed = os.time() - cache.cached_at
            if elapsed < CHECK_CACHE_TTL then
                http.write_json({
                    error = "rate_limited",
                    retry_after = CHECK_CACHE_TTL - elapsed
                })
                return
            end
        end
    end

    local raw = sys.exec("curl -sL -m 10 -A 'PodkopTweaker' '" .. GIT_API_URL .. "' 2>/dev/null")
    if not raw or raw == "" then
        http.write_json({ error = "Failed to connect to GitHub" })
        return
    end

    local release = S.json_parse(raw)
    if not release then
        http.write_json({ error = "Failed to parse GitHub response" })
        return
    end

    if release.message and (release.message:match("rate limit") or release.message:match("API rate")) then
        http.write_json({ error = "GitHub API rate limit exceeded" })
        return
    end

    local tag_name = release.tag_name or ""
    local latest_ver = tag_name:gsub("^v", "")
    local download_url = ""

    if release.assets and type(release.assets) == "table" then
        for _, asset in ipairs(release.assets) do
            if asset.browser_download_url then
                download_url = asset.browser_download_url
                break
            end
        end
    end

    local update_available = version_lt(APP_VERSION, latest_ver)

    local cache_entry = {
        current_version = APP_VERSION,
        latest_version = latest_ver,
        update_available = update_available,
        download_url = download_url,
        cached_at = os.time()
    }
    local cache_str = S.json_stringify(cache_entry)
    if cache_str then
        local cfd = io.open(CHECK_CACHE_FILE, "w")
        if cfd then
            cfd:write(cache_str)
            cfd:close()
        end
    end

    http.write_json({
        current_version = APP_VERSION,
        latest_version = latest_ver,
        update_available = update_available,
        download_url = download_url
    })
end

function api_tweaker_git_update()
    if not verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    set_no_cache_headers()

    local ok, err = pcall(function()
        local download_url = http.formvalue("download_url") or ""
        local force = http.formvalue("force") == "1"

        if download_url == "" then
            http.write_json({ error = "Download URL is required" })
            return
        end
        if not download_url:match("^https://github%.com/InsaniaQuon/luci%-app%-podkop%-tweaker/") then
            http.write_json({ error = "Invalid download URL" })
            return
        end

        local tmp_dir = "/tmp/pt-git-update"
        sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
        sys.exec("mkdir -p " .. tmp_dir .. " 2>/dev/null")

        local archive_path = tmp_dir .. "/download.tar.gz"
        sys.exec("curl -sL -m 60 -o " .. archive_path .. " " .. S.shell_escape(download_url) .. " 2>/dev/null")

        local st = io.open(archive_path, "r")
        if not st then
            http.write_json({ error = "Failed to download archive" })
            sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
            return
        end
        local archive_size = st:seek("end")
        st:close()
        if archive_size > 512000 then
            http.write_json({ error = "Archive too large" })
            sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
            return
        end

        sys.exec("cd " .. tmp_dir .. " && tar -xzf download.tar.gz 2>&1")
        sys.exec("rm -f " .. archive_path .. " 2>/dev/null")

        local extract_dir = tmp_dir
        local ctrl = io.open(extract_dir .. "/usr/lib/lua/luci/controller/podkop-tweaker.lua", "r")
        if not ctrl then
            http.write_json({ error = "Invalid archive" })
            sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
            return
        end
        ctrl:close()

        local valid, verr = validate_archive_structure(extract_dir, true)
        if not valid then
            http.write_json({ error = "Invalid archive" })
            sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
            return
        end

        local archive_ver = extract_version_from_file(extract_dir)
        if not archive_ver then
            http.write_json({ error = "Invalid archive" })
            sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
            return
        end

        if not force and not version_lt(APP_VERSION, archive_ver) then
            http.write_json({ error = "Archive version is not newer than installed" })
            sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
            return
        end

        local copied = S.apply_files_from_dir(extract_dir, true)

        sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
        sys.exec("rm -rf /tmp/luci-modulecache 2>/dev/null")
        os.remove(CHECK_CACHE_FILE)

        sys.exec("nohup /etc/init.d/uhttpd restart >/dev/null 2>&1 &")

        http.write_json({
            success = true,
            new_version = archive_ver,
            files_copied = copied
        })
    end)

    if not ok then
        http.prepare_content("application/json")
        http.write_json({ error = "Internal error" })
    end
end

local function nslookup(domain, server)
    if not server:match("^%d+%.%d+%.%d+%.%d+$") then
        return { ip = "", status = "FAIL", raw = "Invalid server address" }
    end
    if not domain:match("^[%w%.%-]+%.%w+$") then
        return { ip = "", status = "FAIL", raw = "Invalid domain" }
    end
    local cmd = "nslookup " .. domain .. " " .. server .. " 2>&1"
    local fd = io.popen(cmd)
    local raw = fd:read("*a")
    fd:close()
    local ip = ""
    for addr in raw:gmatch("Address:%s*([%d%.]+)") do
        ip = addr
    end
    local fail = raw:find("can't find") or raw:find("timed out") or raw:find("refused") or raw:find("SERVFAIL") or raw:find("no servers")
    return {
        ip = ip,
        status = fail and "FAIL" or (ip ~= "" and "OK" or "FAIL"),
        raw = raw
    }
end

local function get_singbox_inbounds()
    local uci = require("luci.model.uci").cursor()
    local config_path = "/etc/sing-box/config.json"
    uci:foreach("podkop", "section", function(s)
        if s.config_path and s.config_path ~= "" then
            config_path = s.config_path
        end
    end)
    local fd = io.open(config_path, "r")
    if not fd then return {} end
    local content = fd:read("*a")
    fd:close()
    local inbounds = {}
    for ib in content:gmatch('"inbounds"%s*:%s*%[(.-)%]') do
        for block in ib:gmatch("%{(.-)%}") do
            local t = block:match('"type"%s*:%s*"([^"]+)"')
            local port = block:match('"listen_port"%s*:%s*(%d+)')
            local listen = block:match('"listen"%s*:%s*"([^"]+)"')
            if t and port then
                table.insert(inbounds, {
                    type = t,
                    listen = listen or "127.0.0.1",
                    port = tonumber(port)
                })
            end
        end
    end
    return inbounds
end

function api_diag_dns()
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local ok = verify_csrf()
    if not ok then return end

    local uci = require("luci.model.uci").cursor()
    local results = {}
    local domain = "google.com"

    local upstreams = {}
    uci:foreach("stubby", "resolver", function(s)
        if s.address and s.address ~= "" then
            table.insert(upstreams, {
                address = s.address,
                tls_auth_name = s.tls_auth_name or "",
                label = s.tls_auth_name and s.tls_auth_name ~= "" and s.tls_auth_name or s.address
            })
        end
    end)

    for _, up in ipairs(upstreams) do
        local r = nslookup(domain, up.address)
        table.insert(results, {
            source = up.label,
            target = up.address,
            ip = r.ip,
            status = r.status
        })
    end

    local stubby_listen = "127.0.0.53"
    uci:foreach("stubby", "stubby", function(s)
        if s[".name"] == "global" then
            local la = uci:get("stubby", "global", "listen_address")
            if type(la) == "string" then
                stubby_listen = la:match("([%d%.]+)")
            elseif type(la) == "table" and #la > 0 then
                stubby_listen = la[1]:match("([%d%.]+)")
            end
        end
    end)

    local r_stub = nslookup(domain, stubby_listen)
    table.insert(results, {
        source = "Via Stubby",
        target = stubby_listen,
        ip = r_stub.ip,
        status = r_stub.status
    })

    local r_dnsmasq = nslookup(domain, "127.0.0.1")
    table.insert(results, {
        source = "Via dnsmasq",
        target = "127.0.0.1",
        ip = r_dnsmasq.ip,
        status = r_dnsmasq.status
    })

    http.write_json({ results = results })
end

function api_diag_proxy()
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local ok = verify_csrf()
    if not ok then return end

    local results = {}

    local inbounds = get_singbox_inbounds()
    local mixed_port = nil
    for _, ib in ipairs(inbounds) do
        if ib.type == "mixed" then
            mixed_port = ib.port
            break
        end
    end

    if not mixed_port then
        http.write_json({ results = {}, error = "No mixed inbound found in sing-box config" })
        return
    end

    local pid = get_service_pid("sing-box")
    if not pid then
        http.write_json({ results = {}, error = "sing-box is not running" })
        return
    end

    local proxy_url = "http://127.0.0.1:" .. mixed_port
    local cmd = 'curl -s -o /dev/null -w "%{http_code} %{time_total}" -m 10 -x ' .. proxy_url .. ' https://www.google.com 2>&1'
    local start = os.clock()
    local fd = io.popen(cmd)
    local raw = fd:read("*a")
    fd:close()
    local elapsed = math.floor((os.clock() - start) * 1000)

    local code = raw:match("^(%d+)")
    local time_s = raw:match("%d+%s+(%d+%.%d+)")
    local time_ms_real = time_s and math.floor(tonumber(time_s) * 1000) or elapsed

    table.insert(results, {
        source = "sing-box mixed (:" .. mixed_port .. ")",
        http_code = tonumber(code) or 0,
        time_ms = time_ms_real,
        status = (code and tonumber(code) >= 200 and tonumber(code) < 400) and "OK" or "FAIL"
    })

    http.write_json({ results = results })
end

function api_diag_e2e()
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local ok = verify_csrf()
    if not ok then return end

    local results = {}

    local fd = io.popen("curl -s -m 10 https://api.ipify.org 2>&1")
    local ext_ip = fd:read("*a")
    fd:close()
    ext_ip = ext_ip:match("^%d+%.%d+%.%d+%.%d+$") or ext_ip:match("^%S+") or "unknown"

    local fd2 = io.popen('curl -s -o /dev/null -w "%{http_code} %{time_total}" -m 10 https://www.google.com 2>&1')
    local raw = fd2:read("*a")
    fd2:close()

    local code = raw:match("^(%d+)")
    local time_s = raw:match("%d+%s+(%d+%.%d+)")
    local time_ms = time_s and math.floor(tonumber(time_s) * 1000) or 0

    results.external_ip = ext_ip
    results.http_code = tonumber(code) or 0
    results.time_ms = time_ms
    results.status = (code and tonumber(code) >= 200 and tonumber(code) < 400) and "OK" or "FAIL"

    http.write_json(results)
end

function api_diag_dns_leak()
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local ok = verify_csrf()
    if not ok then return end

    local uci = require("luci.model.uci").cursor()
    local results = {}
    local domain = "google.com"

    local upstreams = {}
    uci:foreach("stubby", "resolver", function(s)
        if s.address and s.address ~= "" then
            table.insert(upstreams, s.address)
        end
    end)

    local upstream_ok = false
    if #upstreams > 0 then
        local r_up = nslookup(domain, upstreams[1])
        upstream_ip = r_up.ip
        upstream_ok = (r_up.status == "OK")
    end

    local r_dnsmasq = nslookup(domain, "127.0.0.1")
    local dnsmasq_ok = (r_dnsmasq.status == "OK")

    local leak_detected = false
    local detail = ""
    if dnsmasq_ok and upstream_ok then
        detail = "Both dnsmasq and upstream resolve successfully — no leak detected"
        leak_detected = false
    elseif dnsmasq_ok and not upstream_ok then
        detail = "dnsmasq resolves but upstream is unreachable — dnsmasq may bypass Stubby"
        leak_detected = true
    elseif not dnsmasq_ok and upstream_ok then
        detail = "dnsmasq failed but upstream works — dnsmasq may be misconfigured"
        leak_detected = true
    else
        detail = "Both dnsmasq and upstream failed to resolve"
        leak_detected = true
    end

    results.upstream_ip = upstream_ip
    results.dnsmasq_ip = r_dnsmasq.ip
    results.leak_detected = leak_detected
    results.detail = detail
    results.dnsmasq_status = r_dnsmasq.status

    http.write_json(results)
end

-- === Sing-box Config ===

local SINGBOX_CONFIG = "/etc/sing-box/config.json"
local SINGBOX_BACKUP = SINGBOX_CONFIG .. ".auto-backup"

function api_read_singbox_config()
    local http = require("luci.http")
    http.prepare_content("text/plain")
    set_no_cache_headers()
    local fd = io.open(SINGBOX_CONFIG, "r")
    if fd then
        local content = fd:read("*a")
        fd:close()
        http.write(content)
    else
        http.write("")
    end
end

function api_save_singbox_config()
    if not verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local content = http.formvalue("content") or ""
    if content == "" then
        http.write_json({ error = "Configuration is empty" })
        return
    end
    if #content > 2097152 then
        http.write_json({ error = "Config too large (max 2MB)" })
        return
    end
    if content:find("\0", 1, true) then
        http.write_json({ error = "Invalid content: contains null bytes" })
        return
    end
    local rfd = io.open(SINGBOX_CONFIG, "r")
    if rfd then
        local orig = rfd:read("*a")
        rfd:close()
        if orig == content then
            http.write_json({ success = true, unchanged = true })
            return
        end
        local bfd = io.open(SINGBOX_BACKUP, "w")
        if bfd then
            bfd:write(orig)
            bfd:close()
        end
    end
    local tmp_path = SINGBOX_CONFIG .. ".tmp-write"
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
    os.rename(tmp_path, SINGBOX_CONFIG)
    sys.exec("/etc/init.d/sing-box restart 2>&1")
    http.write_json({ success = true, restarting = true })
end

function api_singbox_service_status()
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local pid = get_service_pid("sing-box")
    http.write_json({
        running = (pid ~= nil),
        pid = pid
    })
end

function api_singbox_service_toggle()
    if not verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local action = http.formvalue("action") or ""
    if action ~= "start" and action ~= "stop" then
        http.write_json({ error = "Invalid action" })
        return
    end
    sys.exec("/etc/init.d/sing-box " .. action .. " 2>&1")
    local pid = get_service_pid("sing-box")
    http.write_json({
        success = true,
        running = (pid ~= nil)
    })
end

function api_rollback_singbox()
    if not verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local fd = io.open(SINGBOX_BACKUP, "r")
    if not fd then
        http.write_json({ error = "Backup file not found" })
        return
    end
    local data = fd:read("*a")
    fd:close()
    local wfd = io.open(SINGBOX_CONFIG, "w")
    if not wfd then
        http.write_json({ error = "Cannot write config" })
        return
    end
    wfd:write(data)
    wfd:close()
    sys.exec("/etc/init.d/sing-box restart 2>&1")
    http.write_json({ success = true, restarting = true })
end

function api_export_singbox_config()
    local http = require("luci.http")
    http.prepare_content("application/octet-stream")
    set_no_cache_headers()
    http.header("Content-Disposition", 'attachment; filename="singbox-config.json"')
    local fd = io.open(SINGBOX_CONFIG, "r")
    if fd then
        local content = fd:read("*a")
        fd:close()
        http.write(content)
    else
        http.status(404, "Not Found")
        http.write("")
    end
end

function api_download_singbox_backup()
    local http = require("luci.http")
    http.prepare_content("application/octet-stream")
    set_no_cache_headers()
    if not io.open(SINGBOX_BACKUP, "r") then
        http.status(404, "Not Found")
        http.write_json({ error = "No sing-box backup found" })
        return
    end
    http.header("Content-Disposition", 'attachment; filename="singbox-backup.json"')
    local fd = io.open(SINGBOX_BACKUP, "r")
    if fd then
        local data = fd:read("*a")
        fd:close()
        http.write(data)
    else
        http.write("")
    end
end

function api_import_singbox_config()
    if not verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local content = http.formvalue("content") or ""
    if content == "" then
        http.write_json({ error = "Empty content" })
        return
    end
    if #content > 2097152 then
        http.write_json({ error = "Config too large (max 2MB)" })
        return
    end
    if content:find("\0", 1, true) then
        http.write_json({ error = "Invalid content: contains null bytes" })
        return
    end
    local tmp_path = SINGBOX_CONFIG .. ".tmp-import"
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
    local rfd = io.open(SINGBOX_CONFIG, "r")
    if rfd then
        local orig = rfd:read("*a")
        rfd:close()
        local bfd = io.open(SINGBOX_BACKUP, "w")
        if bfd then
            bfd:write(orig)
            bfd:close()
        end
    end
    os.rename(tmp_path, SINGBOX_CONFIG)
    sys.exec("/etc/init.d/sing-box restart 2>&1")
    http.write_json({ success = true, restarting = true })
end

function api_singbox_outbounds()
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local raw = sys.exec("jq '.outbounds[] | {tag, type, tls_enabled: (.tls.enabled // false), has_fragment: (.tls.fragment // false)}' " .. SINGBOX_CONFIG .. " 2>/dev/null")
    if not raw or raw == "" then
        http.write_json({ outbounds = {} })
        return
    end
    local outbounds = {}
    local cur = {}
    for line in raw:gmatch("[^\r\n]+") do
        local tag = line:match('"tag":%s*"([^"]+)"')
        local typ = line:match('"type":%s*"([^"]+)"')
        local tls_en = line:match('"tls_enabled":%s*(true)')
        local tls_dis = line:match('"tls_enabled":%s*(false)')
        local frag_en = line:match('"has_fragment":%s*(true)')
        local frag_dis = line:match('"has_fragment":%s*(false)')
        if tag then cur.tag = tag end
        if typ then cur.type = typ end
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

function api_singbox_patch_fragment()
    if not verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    set_no_cache_headers()
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
    local rfd = io.open(SINGBOX_CONFIG, "r")
    if not rfd then
        http.write_json({ error = "Cannot read config" })
        return
    end
    local orig = rfd:read("*a")
    rfd:close()
    local bfd = io.open(SINGBOX_BACKUP, "w")
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
    local jq_expr = '(.outbounds[] | select(' .. jq_select .. ') | .tls) |= . + {"fragment": true, "record_fragment": true}'
    local patched = sys.exec("jq " .. jq_args .. " '" .. jq_expr .. "' " .. SINGBOX_CONFIG .. " 2>/dev/null")
    if not patched or patched == "" then
        http.write_json({ error = "jq patch failed" })
        return
    end
    local tmp_path = SINGBOX_CONFIG .. ".tmp-patch"
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
    os.rename(tmp_path, SINGBOX_CONFIG)
    sys.exec("/etc/init.d/sing-box restart 2>&1")
    http.write_json({ success = true, restarting = true })
end

function api_wrapper_status()
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local fd = io.open("/etc/init.d/podkop.orig", "r")
    http.write_json({
        installed = (fd ~= nil)
    })
    if fd then fd:close() end
end

function api_wrapper_toggle()
    if not verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local action = http.formvalue("action") or ""
    if action ~= "enable" and action ~= "disable" then
        http.write_json({ error = "Invalid action" })
        return
    end
    sys.exec("/etc/init.d/podkop-fragment " .. action .. " 2>&1")
    local fd = io.open("/etc/init.d/podkop.orig", "r")
    http.write_json({
        success = true,
        installed = (fd ~= nil)
    })
    if fd then fd:close() end
end

-- === Podkop Service Toggle ===

function api_podkop_service_toggle()
    if not verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local action = http.formvalue("action") or ""
    if action ~= "start" and action ~= "stop" then
        http.write_json({ error = "Invalid action" })
        return
    end
    sys.exec("/etc/init.d/podkop " .. action .. " 2>&1")
    local pid = get_service_pid("sing-box")
    http.write_json({
        success = true,
        running = (pid ~= nil)
    })
end

function api_podkop_autostart()
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local fd = io.open("/etc/rc.d/S99podkop", "r")
    http.write_json({
        enabled = (fd ~= nil)
    })
    if fd then fd:close() end
end

function api_podkop_autostart_toggle()
    if not verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local action = http.formvalue("action") or ""
    if action ~= "enable" and action ~= "disable" then
        http.write_json({ error = "Invalid action" })
        return
    end
    sys.exec("/etc/init.d/podkop " .. action .. " 2>&1")
    local fd = io.open("/etc/rc.d/S99podkop", "r")
    http.write_json({
        success = true,
        enabled = (fd ~= nil)
    })
    if fd then fd:close() end
end

-- === Stubby Autostart ===

function api_stubby_autostart()
    local http = require("luci.http")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local sys = require("luci.sys")
    local links = sys.exec("ls /etc/rc.d/S*stubby 2>/dev/null")
    http.write_json({
        enabled = (links and links ~= "")
    })
end

function api_stubby_autostart_toggle()
    if not verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    set_no_cache_headers()
    local action = http.formvalue("action") or ""
    if action ~= "enable" and action ~= "disable" then
        http.write_json({ error = "Invalid action" })
        return
    end
    sys.exec("/etc/init.d/stubby " .. action .. " 2>&1")
    local links = sys.exec("ls /etc/rc.d/S*stubby 2>/dev/null")
    http.write_json({
        success = true,
        enabled = (links and links ~= "")
    })
end