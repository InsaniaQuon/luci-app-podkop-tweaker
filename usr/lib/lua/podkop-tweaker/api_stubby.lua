-- Podkop Tweaker | v4.10.2 | 17.10.2026 | Checked service application and owned init repair
-- Hybrid exceptions kept as-is: read_config, export_config, download_backup (transport endpoints)

local SRV = require("podkop-tweaker.services")
local LIB = require("podkop-tweaker.lib")

local M = {}
M.CONFIG_MAX_SIZE = LIB.UCI_MAX_SIZE

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
	option log_level '3'
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

config resolver
	option address '185.222.222.222'
	option tls_auth_name 'dot.sb'
	option tls_port '853'

config resolver
	option address '45.11.45.11'
	option tls_auth_name 'dot.sb'
	option tls_port '853'
]]

function M.read_config()
    require("podkop-tweaker.http").send_text_file("/etc/config/stubby")
end

function M.save_config(content)
    local ok, err = LIB.validate_uci_config(content)
    if not ok then
        return { error = err }
    end
    return SRV.apply_service(SRV.stubby, content, { skip_unchanged = true })
end

function M.service_status()
    return SRV.service_status(SRV.ops.stubby)
end

function M.service_toggle(action)
    return SRV.service_toggle(SRV.ops.stubby, action)
end

function M.rollback()
    return SRV.rollback(SRV.ops.stubby)
end

function M.export_config()
    require("podkop-tweaker.http").send_download("/etc/config/stubby", "stubby-config.txt", "Not Found")
end

function M.download_backup()
    require("podkop-tweaker.http").send_download("/etc/config/stubby.auto-backup", "stubby-backup.txt", "No stubby backup found")
end

function M.chain_info()
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

    return {
        stubby_listen = stubby_listen,
        resolvers = resolvers,
        podkop_dns = podkop_dns
    }
end

function M.init_check()
    local content, err, errno = SRV.read_file("/etc/init.d/stubby", LIB.UCI_MAX_SIZE)
    if not content then
        if errno == 2 then return { status = "not_installed" } end
        return { error = "Cannot read init script", details = err }
    end
    if not content:match("%S") then return { error = "Init script is empty" } end

    if content:match("procd_set_param user stubby") then
        return { status = "needs_fix" }
    end
    return { status = "fixed" }
end

function M.init_fix()
    local function repair_locked()
        local path = "/etc/init.d/stubby"
        local source, read_err, errno = SRV.read_file(path, LIB.UCI_MAX_SIZE)
        if not source then
            return { error = errno == 2 and "Init script not found" or "Cannot read init script", details = read_err }
        end
        if not source:match("%S") then return { error = "Init script is empty" } end
        if not source:match("procd_set_param user stubby") then
            return { success = true, message = "Already fixed" }
        end

        local content = source:gsub("procd_set_param user stubby", "procd_set_param user root")
        local stage, stage_err = SRV.stage_file(path, content, { suffix = ".tmp-fix", executable = true })
        if not stage then return { success = false, error = "Cannot write init script", details = stage_err } end

        local function fail(message, details)
            local cleaned, cleanup_err = SRV.discard_stage(stage)
            if not cleaned then
                local cleanup = "Cannot remove owned init stage " .. stage .. ": " .. tostring(cleanup_err or "Cleanup failed")
                details = details and (details .. "\n" .. cleanup) or cleanup
            end
            return { success = false, error = message, details = details, cleanup_failed = not cleaned or nil }
        end

        local ok, details = SRV.exec_checked("sh -n " .. LIB.shell_escape(stage))
        if not ok then
            return fail("Init script syntax check failed", details)
        end
        ok, details = SRV.exec_checked("chmod 755 " .. LIB.shell_escape(stage))
        if not ok then
            return fail("Cannot set init script permissions", details)
        end
        local current, current_err = SRV.read_file(path, LIB.UCI_MAX_SIZE)
        if current ~= source then
            return fail(current and "Init script changed during repair" or "Cannot re-read init script", current_err)
        end
        ok, details = SRV.publish_file(stage, path)
        if not ok then
            return fail("Cannot apply init script fix", details)
        end
        local result = SRV.restart_service(SRV.ops.stubby)
        result.applied = true
        return result
    end
    local outcome
    local resp, lock_err, uncertain = SRV.with_lock("stubby", function()
        outcome = repair_locked()
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

function M.import_config(content)
    if content == "" then
        return { error = "Empty content" }
    end
    local ok, err = LIB.validate_uci_config(content)
    if not ok then
        return { error = err }
    end
    return SRV.apply_service(SRV.stubby, content)
end

function M.apply_recommended()
    return SRV.apply_service(SRV.stubby, STUBBY_RECOMMENDED)
end

function M.autostart()
    local ok, links = SRV.exec_checked("[ -d /etc/rc.d ] && [ -r /etc/rc.d ] && [ -x /etc/rc.d ] || exit 1; " ..
        "for link in /etc/rc.d/S*stubby; do " ..
        "if [ -L \"$link\" ] || [ -e \"$link\" ]; then printf '%s\\n' \"$link\"; fi; done")
    if not ok then return { error = "Cannot read Stubby autostart state", details = links } end
    return { enabled = links:match("%S") ~= nil }
end

function M.autostart_toggle(action)
    if action ~= "enable" and action ~= "disable" then
        return { error = "Invalid action" }
    end
    local ok, details = SRV.exec_checked("/etc/init.d/stubby " .. action)
    if not ok then return { success = false, error = "Stubby autostart command failed", details = details } end
    local resp = M.autostart()
    if resp.error then resp.success = false; return resp end
    if resp.enabled ~= (action == "enable") then
        return { success = false, error = "Stubby autostart state did not change as requested", enabled = resp.enabled }
    end
    resp.success = true
    return resp
end

return M
