-- Podkop Tweaker | v4.13.0 | 02.11.2026 | Repeated DNS Checks: context discovery and single-round dig execution
-- Author: InsaniaQuon
-- Plan v2 + F1..F6 amendments (Review.md, 02.11.2026): one POST = one round,
-- dig through exec_bounded with a separate external deadline, two independent
-- outcomes (execution vs DNS answer), retained raw bounded to 512 bytes after
-- a complete capture, context fingerprint re-verified before any DNS command.

local LIB = require("podkop-tweaker.lib")
local SRV = require("podkop-tweaker.services")

local M = {}

M.MIN_ROUNDS, M.MAX_ROUNDS, M.DEFAULT_ROUNDS = 1, 20, 10
M.MIN_INTERVAL, M.MAX_INTERVAL, M.DEFAULT_INTERVAL = 1, 5, 1
M.QTYPE = "A"
M.DIG_TIMEOUT = 2          -- dig +timeout per query attempt, seconds
M.EXEC_TIMEOUT = 4         -- external exec_bounded deadline per command, seconds
M.CAPTURE_LIMIT = 8192     -- exec_bounded captured output bound, bytes
M.RAW_RETAIN = 512         -- retained raw bytes per probe (F1)
M.MAX_TARGETS = 16
M.MAX_ANSWERS = 8
M.CONFIG_LIMIT = 2097152   -- bounded sing-box config read
M.MAX_DOMAIN_LEN = 253

local DNSMASQ_HOST, DNSMASQ_PORT = "127.0.0.1", 53

-- Stable context fingerprint over exactly the fields the paths/targets are
-- built from (F3): re-verified per round; a mismatch means context_changed
-- before any DNS command runs.
local function fingerprint(text)
    local h = 5381
    for i = 1, #text do
        h = (h * 33 + text:byte(i)) % 2147483647
    end
    return string.format("%08x", h)
end

local function valid_ipv4(s)
    return type(s) == "string" and s:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
end

-- Outbound server candidates must look like domain names: dot-separated
-- letter/digit/hyphen labels with an alphabetic TLD; numeric addresses are
-- excluded so dns.servers/bootstrap IPs never enter the target list.
local function looks_like_domain(s)
    if type(s) ~= "string" or #s == 0 or #s > M.MAX_DOMAIN_LEN then return false end
    if valid_ipv4(s) or s:find(":", 1, true) then return false end
    if not s:match("^[%w%-%_]+%.[%w%-%_%.]+$") then return false end
    return s:match("%.%a[%a%d%-%_]*$") ~= nil
end

local function normalize_domain(raw)
    if type(raw) ~= "string" then return nil end
    local d = raw:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if #d == 0 or #d > M.MAX_DOMAIN_LEN then return nil end
    if valid_ipv4(d) or d:find(":", 1, true) then return nil end
    -- label.label[.label...]: Lua 5.1 patterns have no group quantifiers, so
    -- the middle is a plain class run; empty labels are rejected separately.
    if not d:match("^[%w%-%_]+[%.][%w%-%_%.]*[%w%-%_]$") then return nil end
    if d:find("%.%", 1, true) then return nil end
    if not d:match("%.%a[%a%d%-%_]*$") then return nil end
    return d
end

-- Paths (F3/§1.3): "Configured Podkop DNS" plus "Via dnsmasq", deduplicated;
-- v1 supports numeric IPv4 UDP endpoints only, everything else is an explicit
-- unsupported status — never a fallback.
local function read_paths()
    local uci = require("luci.model.uci").cursor()
    local sections, err = uci:get_all("podkop")
    if type(sections) ~= "table" then
        return nil, { code = "path_error", message = "Cannot read Podkop configuration", details = tostring(err) }
    end
    local settings = sections.settings
    if type(settings) ~= "table" then
        return nil, { code = "path_error", message = "Podkop settings section is missing" }
    end
    if settings.dns_type ~= "udp" or type(settings.dns_server) ~= "string" or settings.dns_server == "" then
        return nil, { code = "unsupported_dns",
            message = "Configured Podkop DNS is not a UDP server (v1 supports udp with a numeric IPv4 endpoint)" }
    end
    local host, port = settings.dns_server:match("^([%d%.]+):(%d+)$")
    if host then
        local p = tonumber(port)
        if not p or p < 1 or p > 65535 then host = nil end
    else
        host, port = settings.dns_server:match("^([%d%.]+)$"), "53"
    end
    if not host or not valid_ipv4(host) then
        return nil, { code = "unsupported_dns", message = "Configured Podkop DNS is not a numeric IPv4 endpoint" }
    end
    local paths = { { name = "Configured Podkop DNS", host = host, port = tonumber(port) } }
    if not (host == DNSMASQ_HOST and tonumber(port) == DNSMASQ_PORT) then
        paths[#paths + 1] = { name = "Via dnsmasq", host = DNSMASQ_HOST, port = DNSMASQ_PORT }
    end
    return paths, settings.dns_type, settings.dns_server
end

local function config_path()
    local path = "/etc/sing-box/config.json"
    local uci = require("luci.model.uci").cursor()
    uci:foreach("podkop", "section", function(s)
        if s.config_path and s.config_path ~= "" then path = s.config_path end
    end)
    return path
end

-- Domain outbound servers from the bounded config read (F3): errors stay
-- errors (targets_error), a usable target list may still be empty.
local function read_targets()
    local path = config_path()
    local source, read_err = SRV.read_file(path, M.CONFIG_LIMIT)
    if not source then
        return nil, { code = "targets_error", message = "Cannot read sing-box config", details = tostring(read_err) }
    end
    local found, seen = {}, {}
    for server in source:gmatch('"server"%s*:%s*"([^"]+)"') do
        if looks_like_domain(server) then
            local d = server:lower()
            if not seen[d] then
                seen[d] = true
                found[#found + 1] = d
                if #found >= M.MAX_TARGETS then break end
            end
        end
    end
    return found
end

local function build_context()
    local ctx = {
        qtype = M.QTYPE,
        limits = {
            min_rounds = M.MIN_ROUNDS, max_rounds = M.MAX_ROUNDS, default_rounds = M.DEFAULT_ROUNDS,
            min_interval = M.MIN_INTERVAL, max_interval = M.MAX_INTERVAL, default_interval = M.DEFAULT_INTERVAL
        }
    }
    local paths, perr, dns_type, dns_server = read_paths()
    if not paths then
        ctx.error = perr.message
        ctx.error_code = perr.code
        if perr.details then ctx.details = perr.details end
        return ctx
    end
    ctx.paths = paths
    local targets, terr = read_targets()
    if not targets then
        ctx.targets = {}
        ctx.notes = { terr.message .. "; manual domain entry remains available while the paths are usable" }
    else
        ctx.targets = targets
        if #targets == 0 then
            ctx.notes = { "No domain outbound servers discovered; manual domain entry is available" }
        end
    end
    local seed_parts = { M.QTYPE, dns_type or "", dns_server or "", config_path() }
    for _, path in ipairs(paths) do
        seed_parts[#seed_parts + 1] = path.host .. ":" .. path.port
    end
    for _, target in ipairs(type(targets) == "table" and targets or {}) do
        seed_parts[#seed_parts + 1] = target
    end
    ctx.context_id = fingerprint(table.concat(seed_parts, "|"))
    return ctx
end

function M.context()
    return build_context()
end

-- Retained raw (F1): truncation happens only after a complete capture and
-- never changes the probe outcome; sizes and the truncation flag are explicit.
local function retain_raw(probe, output)
    if type(output) ~= "string" or #output == 0 then
        probe.raw = ""
        return
    end
    if #output <= M.RAW_RETAIN then
        probe.raw = output
    else
        probe.raw = output:sub(1, M.RAW_RETAIN)
        probe.raw_truncated = true
    end
    probe.raw_original_bytes = #output
    probe.raw_retained_bytes = #probe.raw
end

-- dig output parser: RCODE from the header comment, A answers with TTLs and
-- the reported query time. A capture without a parsable header stays unparsed
-- (never a success and never a DNS verdict).
local function parse_dig(output)
    if type(output) ~= "string" then return nil end
    local rcode = output:match("status:%s*([A-Z]+)")
    if not rcode then return nil end
    local dns = { rcode = rcode, answers = {} }
    local qt = output:match("Query time:%s*(%d+)")
    if qt then dns.query_time_ms = tonumber(qt) end
    for line in output:gmatch("[^\r\n]+") do
        local ttl, ip = line:match("^%S+%.?%s+(%d+)%s+IN%s+A%s+([%d%.]+)%s*$")
        if ttl and ip then
            dns.answers[#dns.answers + 1] = { ip = ip, ttl = tonumber(ttl) }
            if #dns.answers >= M.MAX_ANSWERS then break end
        end
    end
    return dns
end

-- One bounded dig probe with the F5 classification: external deadline 124 is
-- a command timeout, unknown capture is execution-unknown, SERVFAIL/NXDOMAIN
-- with normal execution is a DNS answer, NOERROR without A records is a
-- distinct no-record outcome.
local function probe_one(path, domain)
    local cmd = "dig -r " .. LIB.shell_escape("@" .. path.host) ..
        " -p " .. tostring(path.port) ..
        " " .. LIB.shell_escape(domain) .. " " .. M.QTYPE ..
        " +timeout=" .. tostring(M.DIG_TIMEOUT) .. " +tries=1 +noall +comments +answer +stats"
    local ok, output, code, unknown = SRV.exec_bounded(cmd,
        { timeout = M.EXEC_TIMEOUT, limit = M.CAPTURE_LIMIT })
    local probe = {
        server = path.host .. ":" .. path.port,
        path_name = path.name,
        execution = { known = code ~= nil, exit_code = code }
    }
    if unknown then
        probe.status = "unknown"
        probe.execution.known = false
        retain_raw(probe, output)
        return probe
    end
    if code == 124 then
        probe.status = "timeout"
        probe.execution.timed_out = true
        retain_raw(probe, output)
        return probe
    end
    if not ok then
        if type(output) == "string" and
            (output:find("timed out", 1, true) or output:find("no servers could be reached", 1, true)) then
            probe.status = "timeout"
        else
            probe.status = "error"
        end
        retain_raw(probe, output)
        return probe
    end
    retain_raw(probe, output)
    local dns = parse_dig(output)
    if not dns then
        probe.status = "unparsed"
        return probe
    end
    probe.dns = dns
    if dns.rcode == "NOERROR" then
        probe.status = #dns.answers > 0 and "ok" or "no_record"
    else
        probe.status = "dns_fail"
    end
    return probe
end

-- One round (B1): a single target and qtype over 1-2 distinct paths; the
-- caller's order alternates per round and the actual order is echoed back.
-- The context fingerprint is re-verified before any DNS command.
function M.round(domain_raw, round_raw, order_raw, context_id_raw)
    local domain = normalize_domain(domain_raw)
    if not domain then return { error = "Invalid domain" } end
    local round_no = tonumber(round_raw)
    if type(round_no) ~= "number" or round_no ~= math.floor(round_no)
        or round_no < M.MIN_ROUNDS or round_no > M.MAX_ROUNDS then
        return { error = "Invalid round number" }
    end
    if order_raw ~= "AB" and order_raw ~= "BA" then
        return { error = "Invalid path order" }
    end
    if type(context_id_raw) ~= "string" or not context_id_raw:match("^[0-9a-f]+$") then
        return { error = "Invalid context id" }
    end
    local ctx = build_context()
    if ctx.error then
        return { error = ctx.error, error_code = ctx.error_code, details = ctx.details }
    end
    if ctx.context_id ~= context_id_raw then
        return { error = "DNS context changed since discovery; restart the series", error_code = "context_changed" }
    end
    local paths = ctx.paths
    if #paths == 1 and order_raw == "BA" then
        return { error = "Invalid path order for a single path" }
    end
    if order_raw == "BA" then paths = { paths[2], paths[1] } end
    local results = {}
    for i, path in ipairs(paths) do
        local probe = probe_one(path, domain)
        probe.order_position = i
        results[i] = probe
    end
    return {
        round = round_no,
        context_id = ctx.context_id,
        actual_order = order_raw,
        domain = domain,
        qtype = M.QTYPE,
        results = results
    }
end

return M
