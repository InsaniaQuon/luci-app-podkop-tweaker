-- Podkop Tweaker | diagnostics helpers (nslookup, sing-box inbound discovery)
-- Author: InsaniaQuon

local M = {}

function M.parse_lookup_ip(raw)
    local server = raw:match("Server:%s*([%d%.]+)") or ""
    local candidates = {}
    for addr in raw:gmatch("Address[^:%c]*:%s*([%w%.:%#]+)") do
        addr = addr:gsub("%#.*$", "")
        candidates[#candidates + 1] = addr
    end
    local last_quad, last_any = nil, nil
    for _, c in ipairs(candidates) do
        local quad = c:match("^(%d+%.%d+%.%d+%.%d+)")
        if quad then
            if quad ~= server then last_quad = quad end
        else
            last_any = c
        end
    end
    if last_quad then return last_quad end
    if last_any then return last_any end
    return ""
end

function M.nslookup(domain, server)
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
    local ip = M.parse_lookup_ip(raw)
    local fail = raw:find("can't find") or raw:find("timed out") or raw:find("refused") or raw:find("SERVFAIL") or raw:find("no servers")
    return {
        ip = ip,
        status = fail and "FAIL" or (ip ~= "" and "OK" or "FAIL"),
        raw = raw
    }
end

function M.get_singbox_inbounds()
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

return M
