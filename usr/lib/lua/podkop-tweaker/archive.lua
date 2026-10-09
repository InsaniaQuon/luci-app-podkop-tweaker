-- Podkop Tweaker | tar metadata preflight before BusyBox extraction
-- gzip output is bounded in memory; no archive member is extracted by this module.
local LIB = require("podkop-tweaker.lib")
local SRV = require("podkop-tweaker.services")
local M = {
    MAX_MEMBERS = 256, MAX_FILE_SIZE = 1048576, MAX_EXPANDED_SIZE = 4194304,
    MAX_STREAM_SIZE = 5242880, MAX_METADATA_SIZE = 16384,
    CONTROLLER = "usr/lib/lua/luci/controller/podkop-tweaker.lua"
}

local EXACT = {
    [M.CONTROLLER] = true,
    ["usr/lib/lua/pt-subs-lib.lua"] = true, ["usr/lib/lua/pt-auto-update.lua"] = true,
    ["usr/share/luci/menu.d/luci-app-podkop-tweaker.json"] = true,
    ["usr/share/rpcd/acl.d/luci-app-podkop-tweaker.json"] = true,
    ["usr/bin/podkop-fragment-patch.sh"] = true, ["etc/init.d/podkop-fragment"] = true,
    ["etc/config/podkop-fragment"] = true, ["etc/config/podkop-tweaker"] = true
}
local NAMESPACES = {
    "usr/lib/lua/podkop-tweaker", "usr/lib/lua/luci/view/podkop-tweaker",
    "www/luci-static/resources/podkop-tweaker"
}

function M.canonical_path(path, directory)
    if type(path) ~= "string" or #path > 256 then return nil end
    if path:sub(1, 2) == "./" then path = path:sub(3) end
    if directory then path = path:gsub("/$", "") end
    if directory and (path == "" or path == ".") then return "" end
    if path == "" or path:sub(1, 1) == "/" or path:sub(-1) == "/" or
        path:find("[^a-zA-Z0-9_./%-]") or path:find("..", 1, true) or path:find("//", 1, true) then return nil end
    for component in path:gmatch("[^/]+") do if component == "." then return nil end end
    if path == "upload.tar.gz" or path == "download.tar.gz" or path == ".pt-manifest.json" then return nil end
    return path
end

function M.is_valid_path(path, relaxed)
    local canonical = M.canonical_path(path, false)
    if not canonical or canonical ~= path then return false end
    if relaxed or EXACT[path] then return true end
    if path:match("^usr/lib/lua/podkop%-tweaker/[a-zA-Z0-9_%-]+%.lua$") then return true end
    if path:match("^usr/lib/lua/luci/view/podkop%-tweaker/[a-zA-Z0-9_%-]+%.htm$") then return true end
    return path:match("^www/luci%-static/resources/podkop%-tweaker/[a-zA-Z0-9_%-]+%.js$") ~= nil or
        path:match("^www/luci%-static/resources/podkop%-tweaker/[a-zA-Z0-9_%-]+%.css$") ~= nil
end

local function valid_directory(path, relaxed)
    if path == "" or relaxed then return true end
    for file in pairs(EXACT) do if file:sub(1, #path + 1) == path .. "/" then return true end end
    for _, namespace in ipairs(NAMESPACES) do
        if namespace == path or namespace:sub(1, #path + 1) == path .. "/" then return true end
    end
    return false
end

local function text_field(header, first, last)
    return header:sub(first, last):match("^[^%z]*")
end

local function octal(value)
    value = value:gsub("%z", ""):match("^%s*(.-)%s*$")
    if value == "" then return 0 end
    if not value:match("^[0-7]+$") then return nil end
    return tonumber(value, 8)
end

local function pax_fields(data)
    local fields, pos = {}, 1
    while pos <= #data do
        local len, first = data:match("^(%d+) ()", pos)
        len = tonumber(len)
        if not len or len < 5 or pos + len - 1 > #data then return nil end
        local record = data:sub(first, pos + len - 1)
        if record:sub(-1) ~= "\n" then return nil end
        local key, value = record:sub(1, -2):match("^([^=]+)=(.*)$")
        if not key or key == "linkpath" or key:match("sparse") or key:match("SCHILY%.filetype") then return nil end
        if key == "path" or key == "size" then fields[key] = value end
        pos = pos + len
    end
    return fields
end

function M.parse_tar(data, relaxed)
    if type(data) ~= "string" or #data > M.MAX_STREAM_SIZE then return nil, "Archive expanded stream is too large" end
    local pos, count, expanded, zeros = 1, 0, 0, 0
    local entries, seen, pending = {}, {}, {}
    local controller = false
    while pos + 511 <= #data do
        local header = data:sub(pos, pos + 511)
        pos = pos + 512
        if header == string.rep("\0", 512) then
            zeros = zeros + 1
            if zeros == 2 then
                if data:sub(pos):find("[^%z]") then return nil, "Data follows tar end marker" end
                if next(pending) then return nil, "Dangling archive metadata" end
                if not controller then return nil, "Controller file not found in archive" end
                return { entries = entries, expanded_size = expanded }
            end
        else
            if zeros > 0 then return nil, "Invalid tar end marker" end
            count = count + 1
            if count > M.MAX_MEMBERS then return nil, "Too many archive members" end
            local checksum = octal(header:sub(149, 156))
            local sum = 0
            for i = 1, 512 do sum = sum + ((i >= 149 and i <= 156) and 32 or header:byte(i)) end
            if not checksum or checksum ~= sum then return nil, "Invalid tar header checksum" end
            local size = octal(header:sub(125, 136))
            if not size then return nil, "Unsupported archive size encoding" end
            local kind = header:sub(157, 157)
            if kind == "x" or kind == "g" or kind == "L" then
                if size > M.MAX_METADATA_SIZE then return nil, "Archive metadata is too large" end
                local block = data:sub(pos, pos + size - 1)
                if #block ~= size then return nil, "Truncated archive metadata" end
                if kind == "L" then
                    pending.path = block:gsub("%z+$", ""):gsub("\n$", "")
                else
                    local fields = pax_fields(block)
                    if not fields then return nil, "Unsupported PAX metadata" end
                    if kind == "g" and next(fields) then return nil, "Unsupported global archive overrides" end
                    for key, value in pairs(fields) do pending[key] = value end
                end
            else
                if kind ~= "0" and kind ~= "\0" and kind ~= "5" then return nil, "Only regular files and directories are allowed" end
                if text_field(header, 158, 257) ~= "" then return nil, "Archive link target is not allowed" end
                local prefix = header:sub(258, 263) == "ustar\0" and text_field(header, 346, 500) or ""
                local name = text_field(header, 1, 100)
                if prefix ~= "" then name = prefix .. "/" .. name end
                name = pending.path or name
                if pending.size then
                    if not pending.size:match("^%d+$") then return nil, "Invalid PAX size" end
                    size = tonumber(pending.size)
                end
                pending = {}
                local directory = kind == "5"
                local path = M.canonical_path(name, directory)
                if not path or (directory and not valid_directory(path, relaxed)) or
                    (not directory and not M.is_valid_path(path, relaxed)) then return nil, "Archive path is not allowed" end
                if directory and size ~= 0 then return nil, "Directory contains data" end
                if size > M.MAX_FILE_SIZE then return nil, "Archive member is too large" end
                expanded = expanded + size
                if expanded > M.MAX_EXPANDED_SIZE then return nil, "Archive expanded size is too large" end
                if #data - pos + 1 < size then return nil, "Truncated archive member" end
                if path ~= "" then
                    if seen[path] then return nil, "Duplicate archive member" end
                    seen[path] = true
                    entries[#entries + 1] = { path = path, size = size, kind = directory and "dir" or "reg" }
                    if path == M.CONTROLLER and not directory then controller = true end
                end
            end
            pos = pos + math.ceil(size / 512) * 512
        end
    end
    return nil, "Truncated tar archive"
end

function M.inspect(path, relaxed)
    local fd = io.popen("gzip -dc " .. LIB.shell_escape(path) .. " 2>/dev/null; printf '\\nPT_GZIP_EXIT:%s\\n' \"$?\"", "r")
    if not fd then return nil, "Cannot inspect archive" end
    local raw, err = SRV.read_stream(fd, M.MAX_STREAM_SIZE + 64)
    fd:close()
    if not raw then return nil, err end
    local tar, status = raw:match("^(.*)\nPT_GZIP_EXIT:(%d+)\n$")
    if not tar or status ~= "0" then return nil, "Invalid gzip archive" end
    return M.parse_tar(tar, relaxed)
end

return M
