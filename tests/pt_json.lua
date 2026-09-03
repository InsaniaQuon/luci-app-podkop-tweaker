-- pt_json | v1.0.0 | 23.08.2026 | Minimal dependency-free JSON codec for test harness (stands in for luci.jsonc)

local M = {}

local FAIL = {}

local ESC_MAP = {
    ['"'] = '\\"',
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t"
}

local function escape_string(s)
    return '"' .. s:gsub("[%z\1-\31\"\\]", function(c)
        return ESC_MAP[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function classify(t)
    local maxn, has_str_keys = 0, false
    for k, _ in pairs(t) do
        if type(k) == "number" then
            if k > maxn then maxn = k end
        else
            has_str_keys = true
        end
    end
    return (not has_str_keys) and maxn > 0, maxn
end

local function encode_value(v, seen)
    local tv = type(v)
    if v == nil then return "null" end
    if tv == "boolean" then return tostring(v) end
    if tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        if math.floor(v) == v and math.abs(v) < 2^53 then
            return string.format("%d", v)
        end
        return tostring(v)
    end
    if tv == "string" then return escape_string(v) end
    if tv == "table" then
        if seen[v] then return "null" end
        seen[v] = true
        local ok, out = pcall(function()
            local is_arr, maxn = classify(v)
            if is_arr then
                local parts = {}
                for i = 1, maxn do parts[#parts + 1] = encode_value(v[i], seen) end
                return "[" .. table.concat(parts, ",") .. "]"
            end
            local keys = {}
            for k, _ in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            local parts = {}
            for _, k in ipairs(keys) do
                parts[#parts + 1] = escape_string(tostring(k)) .. ":" .. encode_value(v[k], seen)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end)
        seen[v] = nil
        if ok then return out end
        return "null"
    end
    return "null"
end

function M.stringify(v)
    return encode_value(v, {})
end

local function skip_ws(s, pos)
    while pos <= #s do
        local c = s:sub(pos, pos)
        if c ~= " " and c ~= "\t" and c ~= "\n" and c ~= "\r" then break end
        pos = pos + 1
    end
    return pos
end

local function decode_utf8(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
    end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end
    return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
        0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

local function parse_string(s, pos)
    pos = pos + 1
    local buf = {}
    while pos <= #s do
        local c = s:sub(pos, pos)
        if c == '"' then return table.concat(buf), pos + 1 end
        if c == "\\" then
            local nxt = s:sub(pos + 1, pos + 1)
            if nxt == "u" then
                local hex = s:sub(pos + 2, pos + 5)
                if not hex:match("^%x%x%x%x$") then return FAIL, pos end
                local cp = tonumber(hex, 16)
                pos = pos + 6
                if cp >= 0xD800 and cp <= 0xDBFF and s:sub(pos, pos + 1) == "\\u" then
                    local lo = s:sub(pos + 2, pos + 5)
                    if lo:match("^%x%x%x%x$") then
                        local low = tonumber(lo, 16)
                        if low >= 0xDC00 and low <= 0xDFFF then
                            cp = 0x10000 + (cp - 0xD800) * 1024 + (low - 0xDC00)
                            pos = pos + 6
                        end
                    end
                end
                buf[#buf + 1] = decode_utf8(cp)
            elseif nxt == "n" then buf[#buf + 1] = "\n"; pos = pos + 2
            elseif nxt == "t" then buf[#buf + 1] = "\t"; pos = pos + 2
            elseif nxt == "r" then buf[#buf + 1] = "\r"; pos = pos + 2
            elseif nxt == "b" then buf[#buf + 1] = "\b"; pos = pos + 2
            elseif nxt == "f" then buf[#buf + 1] = "\f"; pos = pos + 2
            elseif nxt == "/" then buf[#buf + 1] = "/"; pos = pos + 2
            elseif nxt == '"' then buf[#buf + 1] = '"'; pos = pos + 2
            elseif nxt == "\\" then buf[#buf + 1] = "\\"; pos = pos + 2
            else return FAIL, pos end
        else
            buf[#buf + 1] = c
            pos = pos + 1
        end
    end
    return FAIL, pos
end

local function parse_value(s, pos)
    pos = skip_ws(s, pos)
    if pos > #s then return nil, pos end
    local c = s:sub(pos, pos)
    if c == "{" then
        local obj = {}
        pos = skip_ws(s, pos + 1)
        if s:sub(pos, pos) == "}" then return obj, pos + 1 end
        while true do
            pos = skip_ws(s, pos)
            if s:sub(pos, pos) ~= '"' then return FAIL, pos end
            local key
            key, pos = parse_string(s, pos)
            if key == FAIL then return FAIL, pos end
            pos = skip_ws(s, pos)
            if s:sub(pos, pos) ~= ":" then return FAIL, pos end
            local val
            val, pos = parse_value(s, pos + 1)
            if val == FAIL then return FAIL, pos end
            obj[key] = val
            pos = skip_ws(s, pos)
            local d = s:sub(pos, pos)
            if d == "," then pos = pos + 1
            elseif d == "}" then return obj, pos + 1
            else return FAIL, pos end
        end
    elseif c == "[" then
        local arr = {}
        pos = skip_ws(s, pos + 1)
        if s:sub(pos, pos) == "]" then return arr, pos + 1 end
        local i = 0
        while true do
            local val
            i = i + 1
            val, pos = parse_value(s, pos)
            if val == FAIL then return FAIL, pos end
            -- positional semantics like luci.jsonc: JSON null leaves a hole at index i
            if val ~= nil then arr[i] = val end
            pos = skip_ws(s, pos)
            local d = s:sub(pos, pos)
            if d == "," then pos = pos + 1
            elseif d == "]" then return arr, pos + 1
            else return FAIL, pos end
        end
    elseif c == '"' then
        return parse_string(s, pos)
    elseif s:sub(pos, pos + 3) == "true" then
        return true, pos + 4
    elseif s:sub(pos, pos + 4) == "false" then
        return false, pos + 5
    elseif s:sub(pos, pos + 3) == "null" then
        return nil, pos + 4
    else
        local num = s:match("^%-?%d+%.?%d*[eE]?[+-]?%d*", pos)
        if num and num ~= "" and num ~= "-" then
            return tonumber(num), pos + #num
        end
        return FAIL, pos
    end
end

function M.parse(str)
    if type(str) ~= "string" or str == "" then return nil end
    local val, pos = parse_value(str, 1)
    if val == FAIL or pos == nil then return nil end
    pos = skip_ws(str, pos)
    if pos <= #str then return nil end
    return val
end

return M
