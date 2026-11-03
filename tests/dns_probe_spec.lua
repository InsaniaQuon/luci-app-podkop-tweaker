-- dns_probe_spec | v1.0.0 | 02.11.2026 | Repeated DNS Checks: context/round contracts and F1/F5 classification

package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path

local H = require("pt_harness")

local GOOD_DIG = ";; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1\n" ..
    ";; ANSWER SECTION:\nexample.com.\t300\tIN\tA\t93.184.216.34\n" ..
    ";; Query time: 41 msec\n;; SERVER: 127.0.0.53#53(127.0.0.53)\n"
local SERVFAIL_DIG = ";; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 2\n;; Query time: 5100 msec\n"
local NXDOMAIN_DIG = ";; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 3\n;; Query time: 12 msec\n"
local NOANSWER_DIG = ";; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 4\n;; Query time: 8 msec\n"
local COMMS_TIMEOUT_DIG = ";; communications error to 127.0.0.53#53: timed out\n"
local NO_HEADER_DIG = "something odd happened here\n"

local CONFIG = '{"outbounds":[' ..
    '{"type":"vless","tag":"a-out","server":"proxy.example.com"},' ..
    '{"type":"vless","tag":"b-out","server":"second.example.org"},' ..
    '{"type":"direct","tag":"direct-out","server":"1.2.3.4"}],' ..
    '"dns":{"servers":[{"type":"udp","server":"127.0.0.53"}]}}'

local function dig_fixture(out, code)
    return out .. "\nPT_EXIT:" .. tostring(code) .. "\n"
end

-- dig responder: path A is the configured server (@127.0.0.53), path B is
-- dnsmasq (@127.0.0.1); each side has its own fixture.
local function begin_probe(opts)
    opts = opts or {}
    local a = opts.dig_a or dig_fixture(GOOD_DIG, 0)
    local b = opts.dig_b or dig_fixture(GOOD_DIG, 0)
    local pipes = {}
    if opts.dig ~= false then
        pipes[#pipes + 1] = {
            match = function(cmd) return cmd:find("dig -r", 1, true) ~= nil end,
            out = function(cmd)
                if cmd:find("@127%.0%.0%.1", 1) or cmd:find("@127.0.0.1", 1, true) then
                    return type(b) == "function" and b(cmd) or b
                end
                return type(a) == "function" and a(cmd) or a
            end
        }
    end
    opts.uci = opts.uci ~= nil and opts.uci
        or { podkop = { H.sec("settings", "settings", { dns_type = "udp", dns_server = "127.0.0.53:53" }) } }
    opts.popen = pipes
    H.begin(opts)
    -- The harness UCI fake ships no get_all (same as api_stubby_spec): provide
    -- the native package read the production code relies on.
    local pkg = opts.uci.podkop
    local uci = require("luci.model.uci").cursor()
    uci.get_all = function(self, config)
        if config ~= "podkop" then return nil, "unknown config" end
        if not pkg then return nil, "Failed to read podkop package" end
        local map = {}
        for _, section in ipairs(pkg) do map[section[".name"]] = section end
        return map
    end
    if not opts.no_config then
        H.vfs_write("/etc/sing-box/config.json", opts.config or CONFIG)
    end
    return H.reload("podkop-tweaker.dns_probe")
end

local function ctx_id_of(PROBE)
    local ctx = PROBE.context()
    assert.is_not_nil(ctx.context_id, "usable context must carry a fingerprint")
    return ctx
end

after_each(function()
    H.finish()
end)

describe("dns_probe.context", function()
    it("usable: two paths, domain targets deduped, IP servers excluded, limits", function()
        local PROBE = begin_probe()
        local ctx = PROBE.context()
        assert.is_nil(ctx.error)
        assert.equals(2, #ctx.paths)
        assert.equals("Configured Podkop DNS", ctx.paths[1].name)
        assert.equals(53, ctx.paths[1].port)
        assert.equals("Via dnsmasq", ctx.paths[2].name)
        assert.same({ "proxy.example.com", "second.example.org" }, ctx.targets)
        assert.equals("A", ctx.qtype)
        assert.equals(10, ctx.limits.default_rounds)
        assert.equals(1, ctx.limits.default_interval)
        assert.truthy(ctx.context_id:match("^[0-9a-f]+$"))
    end)

    it("deduplicates paths when the configured DNS is already dnsmasq", function()
        local PROBE = begin_probe({
            uci = { podkop = { H.sec("settings", "settings", { dns_type = "udp", dns_server = "127.0.0.1:53" }) } }
        })
        local ctx = PROBE.context()
        assert.is_nil(ctx.error)
        assert.equals(1, #ctx.paths)
    end)

    it("dns_server without port defaults to 53", function()
        local PROBE = begin_probe({
            uci = { podkop = { H.sec("settings", "settings", { dns_type = "udp", dns_server = "127.0.0.53" }) } }
        })
        assert.equals(53, PROBE.context().paths[1].port)
    end)

    it("non-udp dns_type is an explicit unsupported status", function()
        local PROBE = begin_probe({
            uci = { podkop = { H.sec("settings", "settings", { dns_type = "tls", dns_server = "127.0.0.53:53" }) } }
        })
        local ctx = PROBE.context()
        assert.truthy(ctx.error)
        assert.equals("unsupported_dns", ctx.error_code)
    end)

    it("hostname dns_server is unsupported (v1: numeric IPv4 only)", function()
        local PROBE = begin_probe({
            uci = { podkop = { H.sec("settings", "settings", { dns_type = "udp", dns_server = "dns.example.com" }) } }
        })
        assert.equals("unsupported_dns", PROBE.context().error_code)
    end)

    it("missing podkop package is a path error, never defaults", function()
        local PROBE = begin_probe({ uci = {} })
        local ctx = PROBE.context()
        assert.truthy(ctx.error)
        assert.equals("path_error", ctx.error_code)
    end)

    it("unreadable config is a targets_error note with usable paths; manual entry stays possible", function()
        local PROBE = begin_probe({ no_config = true })
        local ctx = PROBE.context()
        assert.is_nil(ctx.error)
        assert.equals(2, #ctx.paths)
        assert.same({}, ctx.targets)
        assert.truthy(ctx.notes and ctx.notes[1]:find("Cannot read sing%-box config"),
            "note: " .. tostring(ctx.notes and ctx.notes[1]))
    end)

    it("config without domain servers yields an empty target list note", function()
        local PROBE = begin_probe({ config = '{"outbounds":[{"type":"direct","server":"10.0.0.1"}]}' })
        local ctx = PROBE.context()
        assert.same({}, ctx.targets)
        assert.truthy(ctx.notes and ctx.notes[1]:find("No domain outbound servers"))
    end)
end)

describe("dns_probe.round validation", function()
    it("rejects bad domain, round, order and context id without any dig", function()
        local PROBE = begin_probe()
        local ctx = ctx_id_of(PROBE)
        assert.equals("Invalid domain", PROBE.round("not a domain", 1, "AB", ctx.context_id).error)
        assert.equals("Invalid round number", PROBE.round("example.com", 0, "AB", ctx.context_id).error)
        assert.equals("Invalid round number", PROBE.round("example.com", 21, "AB", ctx.context_id).error)
        assert.equals("Invalid round number", PROBE.round("example.com", 1.5, "AB", ctx.context_id).error)
        assert.equals("Invalid path order", PROBE.round("example.com", 1, "XX", ctx.context_id).error)
        assert.equals("Invalid context id", PROBE.round("example.com", 1, "AB", "zzzz").error)
        local digs = 0
        for _, cmd in ipairs(H.popen_cmds()) do
            if cmd:find("dig -r", 1, true) then digs = digs + 1 end
        end
        assert.equals(0, digs, "validation failures never run DNS commands")
    end)

    it("context mismatch is context_changed before any dig", function()
        local PROBE = begin_probe()
        local r = PROBE.round("example.com", 1, "AB", "deadbeef")
        assert.equals("context_changed", r.error_code)
        assert.truthy(r.error:find("context changed"))
        local digs = 0
        for _, cmd in ipairs(H.popen_cmds()) do
            if cmd:find("dig -r", 1, true) then digs = digs + 1 end
        end
        assert.equals(0, digs)
    end)

    it("BA order over a single path is rejected", function()
        local PROBE = begin_probe({
            uci = { podkop = { H.sec("settings", "settings", { dns_type = "udp", dns_server = "127.0.0.1:53" }) } }
        })
        local ctx = ctx_id_of(PROBE)
        local r = PROBE.round("example.com", 1, "BA", ctx.context_id)
        assert.equals("Invalid path order for a single path", r.error)
    end)
end)

describe("dns_probe.round outcomes (F5 classification)", function()
    it("NOERROR with answers is ok; SERVFAIL is a dns_fail DNS answer", function()
        local PROBE = begin_probe({ dig_a = dig_fixture(GOOD_DIG, 0), dig_b = dig_fixture(SERVFAIL_DIG, 0) })
        local ctx = ctx_id_of(PROBE)
        local r = PROBE.round("example.com", 1, "AB", ctx.context_id)
        assert.is_nil(r.error)
        assert.equals("AB", r.actual_order)
        assert.equals(1, r.round)
        assert.equals(2, #r.results)
        local a, b = r.results[1], r.results[2]
        assert.equals("ok", a.status)
        assert.equals(1, a.order_position)
        assert.equals("NOERROR", a.dns.rcode)
        assert.equals(41, a.dns.query_time_ms)
        assert.equals(1, #a.dns.answers)
        assert.equals("93.184.216.34", a.dns.answers[1].ip)
        assert.equals(300, a.dns.answers[1].ttl)
        assert.equals(0, a.execution.exit_code)
        assert.equals("dns_fail", b.status)
        assert.equals("SERVFAIL", b.dns.rcode)
        assert.equals(2, b.order_position)
    end)

    it("NOERROR without A records is no_record, not a failure to run", function()
        local PROBE = begin_probe({ dig_a = dig_fixture(NOANSWER_DIG, 0), dig_b = dig_fixture(NXDOMAIN_DIG, 0) })
        local ctx = ctx_id_of(PROBE)
        local r = PROBE.round("example.com", 2, "BA", ctx.context_id)
        assert.equals("BA", r.actual_order)
        -- BA order: results[1] is dnsmasq (dig_b), results[2] is the configured path (dig_a)
        assert.equals("dns_fail", r.results[1].status)
        assert.equals("NXDOMAIN", r.results[1].dns.rcode)
        assert.equals("Via dnsmasq", r.results[1].path_name)
        assert.equals("no_record", r.results[2].status)
        assert.equals(0, #r.results[2].dns.answers)
        assert.equals("Configured Podkop DNS", r.results[2].path_name)
    end)

    it("external deadline 124 is a command timeout, not a DNS RCODE", function()
        local PROBE = begin_probe({
            dig_a = dig_fixture("", 124), dig_b = dig_fixture(GOOD_DIG, 0)
        })
        local ctx = ctx_id_of(PROBE)
        local r = PROBE.round("example.com", 1, "AB", ctx.context_id)
        assert.equals("timeout", r.results[1].status)
        assert.is_true(r.results[1].execution.timed_out)
        assert.equals(124, r.results[1].execution.exit_code)
        assert.is_nil(r.results[1].dns)
        assert.equals("ok", r.results[2].status, "the second path still runs")
    end)

    it("dig-reported timeout with a known nonzero exit is a timeout", function()
        local PROBE = begin_probe({
            dig_a = dig_fixture(COMMS_TIMEOUT_DIG, 9), dig_b = dig_fixture(COMMS_TIMEOUT_DIG, 9)
        })
        local ctx = ctx_id_of(PROBE)
        local r = PROBE.round("example.com", 1, "AB", ctx.context_id)
        assert.equals("timeout", r.results[1].status)
        assert.equals("timeout", r.results[2].status)
        assert.is_falsy(r.results[1].execution.timed_out)
    end)

    it("nonzero exit without a timeout message is a local execution error", function()
        local PROBE = begin_probe({
            dig_a = dig_fixture("dig: parse error\n", 9), dig_b = dig_fixture(GOOD_DIG, 0)
        })
        local ctx = ctx_id_of(PROBE)
        local r = PROBE.round("example.com", 1, "AB", ctx.context_id)
        assert.equals("error", r.results[1].status)
        assert.equals(9, r.results[1].execution.exit_code)
    end)

    it("missing final marker stays execution-unknown even with visible output", function()
        local PROBE = begin_probe({
            dig_a = GOOD_DIG, dig_b = GOOD_DIG -- no PT_EXIT marker at all
        })
        local ctx = ctx_id_of(PROBE)
        local r = PROBE.round("example.com", 1, "AB", ctx.context_id)
        assert.equals("unknown", r.results[1].status)
        assert.is_false(r.results[1].execution.known)
        assert.is_nil(r.results[1].dns, "a NOERROR visible in an unconfirmed capture is not a verdict")
        assert.equals("unknown", r.results[2].status)
    end)

    it("exit 0 without a parsable header is unparsed, never ok", function()
        local PROBE = begin_probe({
            dig_a = dig_fixture(NO_HEADER_DIG, 0), dig_b = dig_fixture(GOOD_DIG, 0)
        })
        local ctx = ctx_id_of(PROBE)
        local r = PROBE.round("example.com", 1, "AB", ctx.context_id)
        assert.equals("unparsed", r.results[1].status)
        assert.is_nil(r.results[1].dns)
    end)
end)

describe("dns_probe.round retained raw (F1)", function()
    it("truncates retained raw after a complete capture without changing the outcome", function()
        local padding = string.rep("x", 700)
        local long_out = GOOD_DIG .. padding .. "\n"
        local PROBE = begin_probe({ dig_a = dig_fixture(long_out, 0), dig_b = dig_fixture(GOOD_DIG, 0) })
        local ctx = ctx_id_of(PROBE)
        local r = PROBE.round("example.com", 1, "AB", ctx.context_id)
        local a = r.results[1]
        assert.equals("ok", a.status, "retained-raw truncation never downgrades a confirmed answer")
        assert.is_true(a.raw_truncated)
        assert.equals(512, a.raw_retained_bytes)
        assert.equals(#long_out, a.raw_original_bytes)
        assert.equals(512, #a.raw)
        assert.is_nil(r.results[2].raw_truncated)
        assert.equals(#GOOD_DIG, r.results[2].raw_original_bytes)
    end)

    it("short outputs are retained whole with explicit sizes", function()
        local PROBE = begin_probe()
        local ctx = ctx_id_of(PROBE)
        local r = PROBE.round("example.com", 1, "AB", ctx.context_id)
        assert.is_nil(r.results[1].raw_truncated)
        assert.equals(#GOOD_DIG, r.results[1].raw_original_bytes)
        assert.equals(#GOOD_DIG, r.results[1].raw_retained_bytes)
    end)
end)
