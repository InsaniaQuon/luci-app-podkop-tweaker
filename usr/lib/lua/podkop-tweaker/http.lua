-- Podkop Tweaker | HTTP helpers: CSRF, cache headers, service pid
-- Author: InsaniaQuon

local M = {}

local PT_CSRF_FILE = "/etc/podkop-tweaker.token"

function M.ensure_csrf_token()
    local fd = io.open(PT_CSRF_FILE, "r")
    if fd then
        local tok = fd:read("*l") or ""
        fd:close()
        tok = tok:match("^%s*(.-)%s*$")
        if tok ~= "" then return tok end
    end
    local rnd = io.open("/dev/urandom", "rb")
    if not rnd then return "" end
    local raw = rnd:read(32)
    rnd:close()
    if not raw or #raw < 32 then return "" end
    local tok = raw:gsub(".", function(c) return string.format("%02x", c:byte()) end)
    if #tok ~= 64 then return "" end
    local wfd = io.open(PT_CSRF_FILE, "w")
    if not wfd then return "" end
    wfd:write(tok)
    wfd:close()
    os.execute("chmod 600 " .. PT_CSRF_FILE .. " 2>/dev/null")
    return tok
end

function M.verify_csrf()
    local http = require("luci.http")
    local expected = M.ensure_csrf_token()
    if expected == "" then
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

function M.no_cache()
    local http = require("luci.http")
    http.header("Cache-Control", "no-cache, no-store, must-revalidate")
    http.header("Pragma", "no-cache")
    http.header("Expires", "0")
end

function M.get_service_pid(process_name)
    local sys = require("luci.sys")
    return sys.exec("pidof " .. process_name .. " 2>/dev/null"):match("(%d+)")
end

return M
