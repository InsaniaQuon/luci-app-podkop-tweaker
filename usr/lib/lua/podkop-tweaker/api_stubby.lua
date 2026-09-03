-- Podkop Tweaker | v4.4.0 | 30.08.2026 | transport via http.lua helpers, init_fix checks mv exit code
-- Hybrid exceptions kept as-is: read_config, export_config, download_backup (transport endpoints)

local SRV = require("podkop-tweaker.services")
local LIB = require("podkop-tweaker.lib")
local S = require("pt-subs-lib")

local M = {}

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

config resolver
	option address '185.222.222.222'
	option tls_auth_name 'dns.sb'
	option tls_port '853'

config resolver
	option address '45.11.45.11'
	option tls_auth_name 'dns.sb'
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
    local orig = SRV.read_file(SRV.stubby.config)
    if orig then
        if orig == content then
            return { success = true, unchanged = true }
        end
        if not SRV.backup_current(SRV.stubby) then
            return { error = "Cannot create backup" }
        end
    end
    ok, err = SRV.write_file_atomic(SRV.stubby.config, content)
    if not ok then
        return { error = err }
    end
    require("luci.sys").exec(SRV.stubby.restart_cmd)
    return { success = true, restarting = true }
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
    local fd = io.open("/etc/init.d/stubby", "r")
    if not fd then
        return { status = "not_installed" }
    end
    local content = fd:read("*a")
    fd:close()

    if content:match("procd_set_param user stubby") then
        return { status = "needs_fix" }
    end
    return { status = "fixed" }
end

function M.init_fix()
    local sys = require("luci.sys")

    local fd = io.open("/etc/init.d/stubby", "r")
    if not fd then
        return { error = "Init script not found" }
    end
    local content = fd:read("*a")
    fd:close()

    if not content:match("procd_set_param user stubby") then
        return { success = true, message = "Already fixed" }
    end

    content = content:gsub("procd_set_param user stubby", "procd_set_param user root")
    local tmp_path = "/etc/init.d/stubby.tmp-fix"
    local tmpfd = io.open(tmp_path, "w")
    if not tmpfd then
        return { error = "Cannot write init script" }
    end
    tmpfd:write(content)
    tmpfd:close()
    local output = sys.exec("chmod +x " .. tmp_path .. " && mv " .. tmp_path .. " /etc/init.d/stubby 2>&1; echo EXIT:$?")
    local exit_code = output:match("EXIT:(%d+)") or "1"
    if exit_code ~= "0" then
        os.remove(tmp_path)
        return { error = "Cannot apply init script fix" }
    end
    sys.exec("/etc/init.d/stubby restart 2>&1")

    return { success = true }
end

function M.import_config(content)
    if content == "" then
        return { error = "Empty content" }
    end
    local ok, err = LIB.validate_uci_config(content)
    if not ok then
        return { error = err }
    end
    if not S.backup_stubby_config() then
        return { error = "Cannot create backup" }
    end
    ok, err = SRV.write_file_atomic(SRV.stubby.config, content)
    if not ok then
        return { error = err }
    end
    require("luci.sys").exec(SRV.stubby.restart_cmd)
    return { success = true, restarting = true }
end

function M.apply_recommended()
    if not S.backup_stubby_config() then
        return { error = "Cannot create backup" }
    end
    local ok, err = SRV.write_file_atomic(SRV.stubby.config, STUBBY_RECOMMENDED)
    if not ok then
        return { error = err }
    end
    require("luci.sys").exec(SRV.stubby.restart_cmd)
    return { success = true, restarting = true }
end

function M.autostart()
    local links = require("luci.sys").exec("ls /etc/rc.d/S*stubby 2>/dev/null")
    return {
        enabled = (links and links ~= "")
    }
end

function M.autostart_toggle(action)
    if action ~= "enable" and action ~= "disable" then
        return { error = "Invalid action" }
    end
    local sys = require("luci.sys")
    sys.exec("/etc/init.d/stubby " .. action .. " 2>&1")
    local links = sys.exec("ls /etc/rc.d/S*stubby 2>/dev/null")
    return {
        success = true,
        enabled = (links and links ~= "")
    }
end

return M
