-- Podkop Tweaker | external recursive-resolver observation, not a leak heuristic
-- Protocol reference: https://github.com/macvk/dnsleaktest/tree/v1.4
local NET = require("podkop-tweaker.net")
local M = { PROVIDER = "bash.ws", PROBES = 6 }

local function valid_id(id)
    return type(id) == "string" and #id > 0 and #id <= 63 and
        id:match("^[a-zA-Z0-9][a-zA-Z0-9%-]*$") ~= nil and id:sub(-1) ~= "-"
end

local function valid_ip(ip)
    if type(ip) ~= "string" or #ip > 45 then return false end
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if a then return tonumber(a) <= 255 and tonumber(b) <= 255 and tonumber(c) <= 255 and tonumber(d) <= 255 end
    if not ip:find(":", 1, true) or ip:find("[^%x:]") or ip:find(":::" , 1, true) then return false end
    local groups = 0
    for group in ip:gmatch("[^:]+") do
        if #group > 4 then return false end
        groups = groups + 1
    end
    local _, compressed = ip:gsub("::", "")
    if compressed == 0 and (ip:sub(1, 1) == ":" or ip:sub(-1) == ":") then return false end
    return compressed == 1 and groups < 8 or compressed == 0 and groups == 8
end

local function clean_label(value)
    return type(value) == "string" and value:gsub("%c", " "):sub(1, 200) or ""
end

function M.start()
    local raw, err = NET.fetch("https://bash.ws/id", 256, 10, "PodkopTweaker", true)
    if not raw then return { error = "Cannot create external DNS test", details = err } end
    local id = raw:match("^%s*(.-)%s*$")
    if not valid_id(id) then return { error = "External DNS provider returned an invalid test ID" } end
    local hosts = {}
    for i = 1, M.PROBES do hosts[i] = tostring(i) .. "." .. id .. ".bash.ws" end
    return { success = true, provider = M.PROVIDER, id = id, hosts = hosts, scope = "current_browser" }
end

function M.results(id)
    if not valid_id(id) then return { error = "Invalid DNS observation ID" } end
    local raw, err = NET.fetch("https://bash.ws/dnsleak/test/" .. id .. "?json", 65536, 10, "PodkopTweaker", true)
    if not raw then return { error = "Cannot read external DNS observations", details = err } end
    local ok, parsed = pcall(require("luci.jsonc").parse, raw)
    if not ok or type(parsed) ~= "table" or #parsed > 128 then return { error = "Invalid DNS observation response" } end
    local resolvers, control_ips, seen = {}, {}, {}
    for _, row in ipairs(parsed) do
        if type(row) == "table" and (row.type == "dns" or row.type == "ip") and valid_ip(row.ip) then
            local key = row.type .. ":" .. row.ip
            if not seen[key] then
                seen[key] = true
                local target = row.type == "dns" and resolvers or control_ips
                target[#target + 1] = { ip = row.ip, country = clean_label(row.country_name), asn = clean_label(row.asn) }
            end
        end
    end
    -- The provider's generic VPN/ASN conclusion is deliberately not used:
    -- Podkop split-routing and different recursive egress pools need context.
    return {
        success = true, provider = M.PROVIDER, id = id, scope = "current_browser",
        control_request_scope = "router", control_request_ips = control_ips,
        resolvers = resolvers, complete = #resolvers > 0,
        conclusion = #resolvers > 0 and "Resolver observations collected; compare with your intended DNS/routing policy" or
            "No resolver observations yet; no conclusion about DNS leaks is possible"
    }
end

return M
