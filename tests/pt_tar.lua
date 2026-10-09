-- Dependency-free USTAR/PAX fixtures; no extraction or filesystem writes.
local M = {}
local function field(value, size) return value .. string.rep("\0", size - #value) end
function M.member(path, content, kind, options)
    options = options or {}
    content = content or ""
    local size = options.size or #content
    local header = field(path, 100) .. field("0000644", 8) .. field("0000000", 8) .. field("0000000", 8) ..
        field(string.format("%011o", size), 12) .. field("00000000000", 12) .. "        " .. (kind or "0") ..
        field(options.link or "", 100) .. "ustar\0" .. "00" .. field("root", 32) .. field("root", 32) ..
        field("", 8) .. field("", 8) .. field(options.prefix or "", 155) .. string.rep("\0", 12)
    local checksum = 0
    for i = 1, #header do checksum = checksum + header:byte(i) end
    header = header:sub(1, 148) .. string.format("%06o\0 ", checksum) .. header:sub(157)
    return header .. content .. string.rep("\0", (512 - #content % 512) % 512)
end
function M.archive(entries)
    local out = {}
    for _, entry in ipairs(entries) do out[#out + 1] = M.member(entry.path, entry.content, entry.kind, entry.options) end
    return table.concat(out) .. string.rep("\0", 1024)
end
function M.pax(key, value)
    local payload = key .. "=" .. value .. "\n"
    local size = #payload + 2
    while #tostring(size) + 1 + #payload ~= size do size = #tostring(size) + 1 + #payload end
    return tostring(size) .. " " .. payload
end
return M
