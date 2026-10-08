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

-- Register before any formvalue()/CSRF call parses the multipart body.
-- Collect bounded file bytes in memory only; no file is written before CSRF.
function M.file_upload(field_name, max_size)
    local http = require("luci.http")
    local chunks, size = {}, 0
    local filename, completed, upload_error

    http.setfilehandler(function(meta, chunk, eof)
        if meta.name ~= field_name or upload_error then return end
        if completed then
            upload_error = "Only one update archive is allowed"
            chunks = {}
            return
        end
        if type(meta.file) ~= "string" or meta.file == "" then
            upload_error = "Missing archive filename"
            return
        end
        filename = meta.file
        if chunk and #chunk > 0 then
            size = size + #chunk
            if size > max_size then
                upload_error = "Archive too large (max " .. max_size .. " bytes)"
                chunks = {}
                return
            end
            chunks[#chunks + 1] = chunk
        end
        if eof then completed = true end
    end)

    return function()
        if upload_error then return nil, nil, upload_error end
        if not filename then return nil, nil, "No file uploaded" end
        if not completed then return nil, nil, "Incomplete archive upload" end
        return table.concat(chunks), filename
    end
end

-- Transport helper: stream a file as text/plain (empty string when missing)
function M.send_text_file(path)
    local http = require("luci.http")
    http.prepare_content("text/plain")
    M.no_cache()
    local fd = io.open(path, "r")
    if fd then
        local content = fd:read("*a")
        fd:close()
        http.write(content)
    else
        http.write("")
    end
end

-- Transport helper: download a file as octet-stream (404 + JSON error when missing)
function M.send_download(path, filename, not_found_msg)
    local http = require("luci.http")
    local fd = io.open(path, "r")
    if not fd then
        http.prepare_content("application/json")
        http.status(404, not_found_msg or "Not Found")
        http.write_json({ error = not_found_msg or "File not found" })
        return
    end
    local content = fd:read("*a")
    fd:close()
    http.prepare_content("application/octet-stream")
    M.no_cache()
    http.header("Content-Disposition", 'attachment; filename="' .. filename .. '"')
    http.write(content)
end

function M.get_service_pid(process_name)
    local sys = require("luci.sys")
    return sys.exec("pidof " .. process_name .. " 2>/dev/null"):match("(%d+)")
end

return M
