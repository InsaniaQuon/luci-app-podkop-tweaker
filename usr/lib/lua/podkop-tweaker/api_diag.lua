-- Podkop Tweaker | v4.2.0 | 23.08.2026 | V2 pure handlers: args in -> response table out; HTTP layer moved to controller adapter

local DIAG = require("podkop-tweaker.diag")

local M = {}

function M.dns()
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
        local r = DIAG.nslookup(domain, up.address)
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

    local r_stub = DIAG.nslookup(domain, stubby_listen)
    table.insert(results, {
        source = "Via Stubby",
        target = stubby_listen,
        ip = r_stub.ip,
        status = r_stub.status
    })

    local r_dnsmasq = DIAG.nslookup(domain, "127.0.0.1")
    table.insert(results, {
        source = "Via dnsmasq",
        target = "127.0.0.1",
        ip = r_dnsmasq.ip,
        status = r_dnsmasq.status
    })

    return { results = results }
end

function M.proxy()
    local results = {}

    local inbounds = DIAG.get_singbox_inbounds()
    local mixed_port = nil
    for _, ib in ipairs(inbounds) do
        if ib.type == "mixed" then
            mixed_port = ib.port
            break
        end
    end

    if not mixed_port then
        return { results = {}, error = "No mixed inbound found in sing-box config" }
    end

    local pid = require("podkop-tweaker.http").get_service_pid("sing-box")
    if not pid then
        return { results = {}, error = "sing-box is not running" }
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

    return { results = results }
end

function M.e2e()
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

    return results
end

function M.dns_leak()
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
    local upstream_ip = ""
    if #upstreams > 0 then
        local r_up = DIAG.nslookup(domain, upstreams[1])
        upstream_ip = r_up.ip
        upstream_ok = (r_up.status == "OK")
    end

    local r_dnsmasq = DIAG.nslookup(domain, "127.0.0.1")
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

    return results
end

return M
