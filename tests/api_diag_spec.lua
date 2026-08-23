-- api_diag_spec | v1.0.0 | 23.08.2026 | Max-coverage specs for V2 pure handlers of api_diag

package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path

local H = require("pt_harness")

local GOOD_1111 = "Server:\t1.1.1.1\nAddress:\t1.1.1.1#53\n\nName:\tgoogle.com\nAddress 1: 142.250.74.14\n"
local GOOD_STUBBY = "Server:\t127.0.0.53\nAddress:\t127.0.0.53#53\n\nName:\tgoogle.com\nAddress 1: 142.250.74.99\n"
local GOOD_DNSMASQ = "Server:\t127.0.0.1\nAddress:\t127.0.0.1:53\nName:\tgoogle.com\nAddress:\t142.250.74.50\n"
local TIMEOUT = ";; connection timed out; no servers could be reached\n"

local function ns_popen(map)
    return function(cmd)
        local server = cmd:match("^nslookup%s+%S+%s+(%S+)%s+2>&1$")
        if server and map[server] then return map[server] end
        if cmd:find("^nslookup") then return "" end
        return nil
    end
end

after_each(function()
    H.finish()
end)

describe("api_diag.dns", function()
    it("full chain: upstreams + stubby + dnsmasq with labels and statuses", function()
        H.begin({
            uci = {
                stubby = {
                    H.sec("global", "stubby", { listen_address = "127.0.0.53@5353" }),
                    H.sec("r1", "resolver", { address = "1.1.1.1", tls_auth_name = "cloudflare-dns.com" }),
                    H.sec("r2", "resolver", { address = "9.9.9.9" })
                }
            },
            popen = ns_popen({
                ["1.1.1.1"] = GOOD_1111,
                ["9.9.9.9"] = TIMEOUT,
                ["127.0.0.53"] = GOOD_STUBBY,
                ["127.0.0.1"] = GOOD_DNSMASQ
            })
        })
        local DIA = H.reload("podkop-tweaker.api_diag")
        local resp = DIA.dns()
        assert.same({
            results = {
                { source = "cloudflare-dns.com", target = "1.1.1.1", ip = "142.250.74.14", status = "OK" },
                { source = "9.9.9.9", target = "9.9.9.9", ip = "", status = "FAIL" },
                { source = "Via Stubby", target = "127.0.0.53", ip = "142.250.74.99", status = "OK" },
                { source = "Via dnsmasq", target = "127.0.0.1", ip = "142.250.74.50", status = "OK" }
            }
        }, resp)
    end)

    it("listen_address as list uses first element ip part", function()
        H.begin({
            uci = {
                stubby = {
                    H.sec("global", "stubby", { listen_address = { "127.0.0.99@853" } })
                }
            },
            popen = ns_popen({ ["127.0.0.99"] = GOOD_STUBBY, ["127.0.0.1"] = GOOD_DNSMASQ })
        })
        local DIA = H.reload("podkop-tweaker.api_diag")
        local r = DIA.dns().results
        assert.equal("Via Stubby", r[1].source)
        assert.equal("127.0.0.99", r[1].target)
    end)

    it("missing global section falls back to default listener", function()
        H.begin({
            uci = { stubby = {} },
            popen = ns_popen({ ["127.0.0.53"] = GOOD_STUBBY, ["127.0.0.1"] = GOOD_DNSMASQ })
        })
        local DIA = H.reload("podkop-tweaker.api_diag")
        local r = DIA.dns().results
        assert.equal("127.0.0.53", r[1].target)
        assert.equal(2, #r)
    end)

    it("resolvers without address are skipped; non-global stubby sections ignored", function()
        H.begin({
            uci = {
                stubby = {
                    H.sec("global", "stubby", {}),
                    H.sec("empty", "resolver", {}),
                    H.sec("other", "stubby", {})
                }
            },
            popen = ns_popen({ ["127.0.0.53"] = GOOD_STUBBY, ["127.0.0.1"] = GOOD_DNSMASQ })
        })
        local DIA = H.reload("podkop-tweaker.api_diag")
        assert.equal(2, #DIA.dns().results)
    end)
end)

describe("api_diag.proxy", function()
    local SB_MIXED = '{\n  "inbounds": [\n    { "type": "tun", "listen_port": 9000 },' ..
        '\n    { "type": "mixed", "listen": "127.0.0.1", "listen_port": 8080 }\n  ]\n}\n'

    local function begin_with(sb_content, sys_out, curl_raw)
        H.begin({
            sys = sys_out and { { match = "pidof sing-box", out = sys_out } } or {},
            popen = function(cmd)
                if cmd:find("%-x http://127%.0%.0%.1:%d+") then return curl_raw or "" end
                return ""
            end
        })
        H.state().vfs["/etc/sing-box/config.json"] = { content = sb_content or "" }
    end

    it("mixed inbound + running service -> OK result", function()
        begin_with(SB_MIXED, "777\n", "200 0.123456\n")
        local DIA = H.reload("podkop-tweaker.api_diag")
        local resp = DIA.proxy()
        assert.falsy(resp.error)
        local e = resp.results[1]
        assert.equal("sing-box mixed (:8080)", e.source)
        assert.equal(200, e.http_code)
        assert.equal(123, e.time_ms)
        assert.equal("OK", e.status)
    end)

    it("no mixed inbound -> exact error, no pidof call", function()
        begin_with('{ "inbounds": [ { "type": "tun", "listen_port": 9000 } ] }', "", "")
        local DIA = H.reload("podkop-tweaker.api_diag")
        local resp = DIA.proxy()
        assert.same({ results = {}, error = "No mixed inbound found in sing-box config" }, resp)
        local pid_calls = 0
        for _, c in ipairs(H.exec_cmds()) do
            if c:find("pidof", 1, true) then pid_calls = pid_calls + 1 end
        end
        assert.equal(0, pid_calls)
    end)

    it("service down -> error before curl", function()
        begin_with(SB_MIXED, "", "")
        local DIA = H.reload("podkop-tweaker.api_diag")
        assert.same({ results = {}, error = "sing-box is not running" }, DIA.proxy())
        assert.equal(0, #H.popen_cmds())
    end)

    it("garbage curl output -> code 0 FAIL with elapsed fallback", function()
        begin_with(SB_MIXED, "1\n", "000\n")
        local DIA = H.reload("podkop-tweaker.api_diag")
        local e = DIA.proxy().results[1]
        assert.equal(0, e.http_code)
        assert.equal("FAIL", e.status)
        assert.equal("number", type(e.time_ms))
    end)

    it("http 500 -> FAIL", function()
        begin_with(SB_MIXED, "1\n", "500 0.25\n")
        local DIA = H.reload("podkop-tweaker.api_diag")
        local e = DIA.proxy().results[1]
        assert.equal(500, e.http_code)
        assert.equal(250, e.time_ms)
        assert.equal("FAIL", e.status)
    end)

    it("config_path override from podkop uci is honored", function()
        H.begin({
            uci = { podkop = { H.sec("sb", "section", { config_path = "/opt/sb.json" }) } },
            sys = { { match = "pidof sing-box", out = "9\n" } },
            popen = function(cmd) if cmd:find(":9090") then return "204 0.05\n" end return "" end
        })
        H.vfs_write("/opt/sb.json", '{ "inbounds": [ { "type": "mixed", "listen_port": 9090 } ] }')
        local DIA = H.reload("podkop-tweaker.api_diag")
        local e = DIA.proxy().results[1]
        assert.equal(204, e.http_code)
        assert.matches(":9090", e.source, 1, true)
    end)
end)

describe("api_diag.e2e", function()
    local function begin_e2e(ipify_raw, google_raw)
        H.begin({
            popen = function(cmd)
                if cmd:find("api%.ipify%.org") then return ipify_raw end
                if cmd:find("google%.com") then return google_raw end
                return ""
            end
        })
    end

    it("success path maps all fields", function()
        begin_e2e("203.0.113.7\n", "200 0.4321\n")
        local DIA = H.reload("podkop-tweaker.api_diag")
        assert.same({
            external_ip = "203.0.113.7",
            http_code = 200,
            time_ms = 432,
            status = "OK"
        }, DIA.e2e())
    end)

    it("invalid ip falls back to first word, empty becomes unknown", function()
        begin_e2e("<html>oops</html>\n", "200 0.10\n")
        local DIA = H.reload("podkop-tweaker.api_diag")
        assert.equal("<html>oops</html>", DIA.e2e().external_ip)
        begin_e2e("", "200 0.10\n")
        local DIA2 = H.reload("podkop-tweaker.api_diag")
        assert.equal("unknown", DIA2.e2e().external_ip)
    end)

    it("google failure -> FAIL with zero time", function()
        begin_e2e("1.2.3.4\n", "000\n")
        local DIA = H.reload("podkop-tweaker.api_diag")
        local r = DIA.e2e()
        assert.equal(0, r.http_code)
        assert.equal(0, r.time_ms)
        assert.equal("FAIL", r.status)
    end)

    it("3xx counts as OK boundary", function()
        begin_e2e("1.2.3.4\n", "301 0.11\n")
        local DIA = H.reload("podkop-tweaker.api_diag")
        assert.equal("OK", DIA.e2e().status)
    end)
end)

describe("api_diag.dns_leak", function()
    local function begin_leak(resolvers, dnsmasq_raw, first_upstream_raw)
        local secs = {}
        for i, a in ipairs(resolvers) do
            secs[#secs + 1] = H.sec("r" .. i, "resolver", { address = a })
        end
        H.begin({
            uci = { stubby = secs },
            popen = ns_popen({
                ["127.0.0.1"] = dnsmasq_raw,
                [resolvers[1] or "-"] = first_upstream_raw
            })
        })
    end

    it("both OK -> no leak, first upstream used only", function()
        begin_leak({ "1.1.1.1", "8.8.8.8" }, GOOD_DNSMASQ, GOOD_1111)
        local DIA = H.reload("podkop-tweaker.api_diag")
        local r = DIA.dns_leak()
        assert.is_false(r.leak_detected)
        assert.equal("142.250.74.14", r.upstream_ip)
        assert.equal("142.250.74.50", r.dnsmasq_ip)
        assert.equal("OK", r.dnsmasq_status)
        assert.matches("no leak detected$", r.detail)
        local lookups = 0
        for _, c in ipairs(H.popen_cmds()) do
            if c:find("^nslookup") then lookups = lookups + 1 end
        end
        assert.equal(2, lookups)
    end)

    it("no upstreams configured -> leak (bypass) text", function()
        begin_leak({}, GOOD_DNSMASQ, "")
        local DIA = H.reload("podkop-tweaker.api_diag")
        local r = DIA.dns_leak()
        assert.is_true(r.leak_detected)
        assert.equal("", r.upstream_ip)
        assert.matches("may bypass Stubby$", r.detail)
    end)

    it("dnsmasq ok, upstream dead -> leak", function()
        begin_leak({ "9.9.9.9" }, GOOD_DNSMASQ, TIMEOUT)
        local DIA = H.reload("podkop-tweaker.api_diag")
        local r = DIA.dns_leak()
        assert.is_true(r.leak_detected)
        assert.matches("upstream is unreachable", r.detail)
    end)

    it("dnsmasq broken, upstream ok -> misconfigured", function()
        begin_leak({ "1.1.1.1" }, TIMEOUT, GOOD_1111)
        local DIA = H.reload("podkop-tweaker.api_diag")
        local r = DIA.dns_leak()
        assert.is_true(r.leak_detected)
        assert.equal("FAIL", r.dnsmasq_status)
        assert.matches("may be misconfigured$", r.detail)
    end)

    it("both broken -> both failed", function()
        begin_leak({ "1.1.1.1" }, TIMEOUT, TIMEOUT)
        local DIA = H.reload("podkop-tweaker.api_diag")
        local r = DIA.dns_leak()
        assert.is_true(r.leak_detected)
        assert.equal("", r.upstream_ip)
        assert.equal("", r.dnsmasq_ip)
        assert.matches("failed to resolve$", r.detail)
    end)
end)
