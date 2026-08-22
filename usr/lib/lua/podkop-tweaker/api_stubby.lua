-- Podkop Tweaker | Stubby config + service API handlers
-- Author: InsaniaQuon

local H = require("podkop-tweaker.http")
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
]]

function M.read_config()
    local http = require("luci.http")
    http.prepare_content("text/plain")
    H.no_cache()
    local fd = io.open("/etc/config/stubby", "r")
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
    local ok, err = LIB.validate_uci_config(content)
    if not ok then
        http.write_json({ error = err })
        return
    end
    local orig = SRV.read_file(SRV.stubby.config)
    if orig then
        if orig == content then
            http.write_json({ success = true, unchanged = true })
            return
        end
        if not SRV.backup_current(SRV.stubby) then
            http.write_json({ error = "Cannot create backup" })
            return
        end
    end
    ok, err = SRV.write_file_atomic(SRV.stubby.config, content)
    if not ok then
        http.write_json({ error = err })
        return
    end
    sys.exec(SRV.stubby.restart_cmd)
    http.write_json({ success = true, restarting = true })
end

function M.service_status()
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()
    local pid = H.get_service_pid("stubby")
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
    sys.exec("/etc/init.d/stubby " .. action .. " 2>&1")
    local pid = H.get_service_pid("stubby")
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
    local ok, err = SRV.restore_backup(SRV.stubby)
    if not ok then
        http.write_json({ error = (err == "not_found") and "Backup file not found" or "Cannot write config" })
        return
    end
    sys.exec(SRV.stubby.restart_cmd)
    http.write_json({ success = true, restarting = true })
end

function M.export_config()
    local http = require("luci.http")
    http.prepare_content("text/plain")
    H.no_cache()
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

function M.download_backup()
    local http = require("luci.http")
    local nixio = require("nixio")
    http.prepare_content("text/plain")
    H.no_cache()
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

function M.chain_info()
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()

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

function M.init_check()
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()

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

function M.init_fix()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    H.no_cache()

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

function M.import_config()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    H.no_cache()
    local content = http.formvalue("content") or ""
    if content == "" then
        http.write_json({ error = "Empty content" })
        return
    end
    local ok, err = LIB.validate_uci_config(content)
    if not ok then
        http.write_json({ error = err })
        return
    end
    if not S.backup_stubby_config() then
        http.write_json({ error = "Cannot create backup" })
        return
    end
    ok, err = SRV.write_file_atomic(SRV.stubby.config, content)
    if not ok then
        http.write_json({ error = err })
        return
    end
    sys.exec(SRV.stubby.restart_cmd)
    http.write_json({ success = true, restarting = true })
end

function M.apply_recommended()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    H.no_cache()
    if not S.backup_stubby_config() then
        http.write_json({ error = "Cannot create backup" })
        return
    end
    local ok, err = SRV.write_file_atomic(SRV.stubby.config, STUBBY_RECOMMENDED)
    if not ok then
        http.write_json({ error = err })
        return
    end
    sys.exec(SRV.stubby.restart_cmd)
    http.write_json({ success = true, restarting = true })
end

function M.autostart()
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()
    local sys = require("luci.sys")
    local links = sys.exec("ls /etc/rc.d/S*stubby 2>/dev/null")
    http.write_json({
        enabled = (links and links ~= "")
    })
end

function M.autostart_toggle()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    H.no_cache()
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

return M
