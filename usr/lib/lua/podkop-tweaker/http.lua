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
function M.file_upload(field_name, max_size, label)
    local http = require("luci.http")
    local chunks, size = {}, 0
    local filename, completed, upload_error
    local noun = label and label:lower() or "archive"

    http.setfilehandler(function(meta, chunk, eof)
        if upload_error then return end
        if meta.name ~= field_name then
            if meta.file then upload_error = "Unexpected uploaded file"; chunks = {} end
            return
        end
        if completed then
            upload_error = "Only one " .. (label and noun or "update archive") .. " is allowed"
            chunks = {}
            return
        end
        if type(meta.file) ~= "string" or meta.file == "" then
            upload_error = "Missing " .. noun .. " filename"
            return
        end
        filename = meta.file
        if chunk and #chunk > 0 then
            size = size + #chunk
            if size > max_size then
                upload_error = (label or "Archive") .. " too large (max " .. max_size .. " bytes)"
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
        if not completed then return nil, nil, "Incomplete " .. noun .. " upload" end
        return table.concat(chunks), filename
    end
end

-- Legacy callers retain empty/missing responses; strict editors reject them.
-- IO errors always have an explicit status instead of becoming an empty 200.
function M.send_text_file(path, options)
    local http = require("luci.http")
    local SRV = require("podkop-tweaker.services")
    options = options or {}
    M.no_cache()
    local function fail(code, message, details)
        http.status(code, message)
        http.prepare_content("application/json")
        http.write_json({ error = message, details = details })
    end
    local fd, open_err, errno = io.open(path, "rb")
    if not fd then
        if errno ~= 2 then return fail(500, "Cannot read configuration file", open_err) end
        if options.require_nonempty then return fail(404, "Configuration file not found", path) end
        http.prepare_content("text/plain")
        http.write("")
        return
    end
    local content, read_err = SRV.read_stream(fd, options.limit or 8388608)
    local closed, close_err = fd:close()
    if not content then return fail(500, "Cannot read configuration file", read_err) end
    if not closed then return fail(500, "Cannot close configuration file", close_err) end
    if options.require_nonempty and not content:match("%S") then
        return fail(409, "Configuration file is empty", path .. ": restore or regenerate the configuration before restarting sing-box.")
    end
    http.prepare_content("text/plain")
    http.write(content)
end

-- Finish the bounded read and close before committing an attachment response.
-- Missing files are distinct from IO/size failures; neither may write raw bytes.
function M.send_download(path, filename, not_found_msg)
    local http = require("luci.http")
    local SRV = require("podkop-tweaker.services")
    M.no_cache()
    local function fail(code, message, details)
        http.status(code, message)
        http.prepare_content("application/json")
        http.write_json({ error = message, details = details })
    end
    local fd, open_err, errno = io.open(path, "rb")
    if not fd then
        if errno == 2 then return fail(404, not_found_msg or "File not found", path) end
        return fail(500, "Cannot read download file", open_err or path)
    end
    local content, read_err = SRV.read_stream(fd, 8388608)
    local closed, close_err = fd:close()
    if not content then return fail(500, "Cannot read download file", read_err or path) end
    if not closed then return fail(500, "Cannot close download file", close_err or path) end
    http.prepare_content("application/octet-stream")
    http.header("Content-Disposition", 'attachment; filename="' .. filename .. '"')
    http.write(content)
end

function M.get_service_pid(process_name)
    local sys = require("luci.sys")
    return sys.exec("pidof " .. process_name .. " 2>/dev/null"):match("(%d+)")
end

return M
