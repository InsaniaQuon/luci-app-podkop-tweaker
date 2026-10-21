-- Podkop Tweaker | v1.0.0 | 19.10.2026 | Read-only Stubby init/runtime/socket facts; bounded literal root candidate
local SRV = require("podkop-tweaker.services")
local LIB = require("podkop-tweaker.lib")
local M = {}
local INIT, CONFIG = "/etc/init.d/stubby", "/etc/config/stubby"

-- Drain the finite native table, retaining at most 64 KiB. Preserve the native
-- exit separately from awk's exit, and never turn overflow into known absence.
M.LISTENER_COMMAND = "{ netstat -lntup 2>&1; printf '\\nPT_STUBBY_NETSTAT:%s\\n' \"$?\"; } | " ..
    "LC_ALL=C awk 'BEGIN { n=0; overflow=0 } { if (n+length($0)+1<=65536) { print; n+=length($0)+1 } else overflow=1 } " ..
    "END { if (overflow) print \"PT_STUBBY_NETSTAT_OVERFLOW\" }'"

local function unknown(message)
    return { state = "unknown", error = message }
end

-- Literal, single-physical-line shell words with exact byte spans. This is a
-- deliberately bounded init format, never shell evaluation. Refuse multiline
-- payloads/continuations/heredocs rather than rewriting their text as commands.
local function shell_words(line)
    local words, word, start, quote, escaped, dynamic = {}, "", nil, nil, false, false
    local function finish(last)
        if start then words[#words + 1] = { value = word, first = start, last = last, dynamic = dynamic } end
        word, start, dynamic = "", nil, false
    end
    for pos = 1, #line do
        local char = line:sub(pos, pos)
        if escaped then word, escaped = word .. char, false
        elseif quote then
            if char == quote then quote = nil
            elseif char == "\\" and quote == '"' then escaped = true
            else
                if quote == '"' and (char == "$" or char == "`") then dynamic = true end
                word = word .. char
            end
        elseif char == "#" and not start then break
        elseif char == " " or char == "\t" or char == "\r" then finish(pos - 1)
        elseif not quote and char == "<" and line:sub(pos + 1, pos + 1) == "<" then return nil, "Heredoc init layout requires manual review"
        elseif char:match("[;&|<>(){}]") then
            finish(pos - 1)
            words[#words + 1] = { value = char, first = pos, last = pos, operator = true }
        else
            start = start or pos
            if char == "'" or char == '"' then quote = char
            elseif char == "\\" then escaped = true
            elseif char == "$" or char == "`" then dynamic, word = true, word .. char
            else word = word .. char end
        end
        if #word > 1024 then return nil, "Init token exceeds the supported bounded layout" end
    end
    if quote or escaped then return nil, "Multiline shell payload or continuation requires manual review" end
    finish(#line)
    return words
end

local function inspect_init(content)
    if type(content) ~= "string" or #content > LIB.UCI_MAX_SIZE then return unknown("Invalid or oversized init script") end
    if content:find("[%z\1-\8\11-\31\127]") then return unknown("Unsupported control bytes in init script") end
    local found, current, offset, starts = {}, nil, 1, 0
    for physical in (content .. "\n"):gmatch("([^\n]*)\n") do
        local words, err = shell_words(physical)
        if not words then return unknown(err) end
        local plain = physical:gsub("%s+#.*$", ""):match("^%s*(.-)%s*$")
        local fn = plain:match("^([%a_][%w_]*)%s*%(%s*%)%s*{?%s*$")
        if fn then
            current = fn
            if fn == "start_service" then
                starts = starts + 1
                if starts > 1 then return unknown("Duplicate start_service definitions require manual review") end
            end
        end
        for index, token in ipairs(words) do
            if token.value == "procd_set_param" or token.value == "procd_append_param" then
                local key = words[index + 1]
                if key and key.value == "user" then
                    local value, tail = words[index + 2], words[index + 3]
                    if current ~= "start_service" or index ~= 1 or token.dynamic or token.value ~= "procd_set_param" or
                        not value or value.dynamic or not value.value:match("^[%w_%-]+$") or #value.value > 32 or
                        tail and (tail.value ~= ";" or words[index + 4]) then
                        return unknown("Non-literal or ambiguous init user declaration requires manual review")
                    end
                    found[#found + 1] = { user = value.value, first = offset + value.first - 1, last = offset + value.last - 1 }
                end
            end
        end
        if plain == "}" then current = nil end
        offset = offset + #physical + 1
    end
    if #found ~= 1 then return unknown("Expected one explicit init user declaration inside start_service") end
    return { state = "literal", user = found[1].user }, found[1]
end

function M.root_candidate(content)
    local init, span = inspect_init(content)
    if init.state ~= "literal" then return nil, init.error end
    if init.user == "root" or init.user == "0" then return content, nil, true end
    if init.user ~= "stubby" then return nil, "Custom init user requires manual review" end
    return content:sub(1, span.first - 1) .. "root" .. content:sub(span.last + 1)
end

local function instance(pid)
    local text, err = SRV.read_file("/proc/" .. pid .. "/stat", 4096)
    if not text then return nil, err end
    local fields = text:match("^" .. pid .. " %b() (.+)$")
    local index = 0
    for value in (fields or ""):gmatch("%S+") do
        index = index + 1
        if index == 20 and value:match("^%d+$") then return pid .. ":" .. value end
    end
    return nil, "Invalid process identity for PID " .. pid
end

local function runtime()
    local ok, text, code = SRV.exec_checked("pidof 'stubby' 2>/dev/null")
    if code == 1 and not text:match("%S") then return { state = "stopped", processes = {}, process_count = 0 } end
    if not ok then return unknown("Cannot query Stubby processes: " .. text) end
    if #text > 1024 or text:gsub("%d", ""):match("%S") then return unknown("Invalid Stubby PID response") end
    local processes, seen, euid = {}, {}, nil
    local mixed = false
    for pid in text:gmatch("%d+") do
        if #processes >= 16 or seen[pid] or not tonumber(pid) or tostring(tonumber(pid)) ~= pid or tonumber(pid) < 1 or tonumber(pid) > 2147483647 then
            return unknown("Invalid, duplicate or excessive Stubby PID list")
        end
        seen[pid] = true
        local before, err = instance(pid)
        if not before then return unknown(err) end
        local status
        status, err = SRV.read_file("/proc/" .. pid .. "/status", 16384)
        if not status then return unknown(err) end
        local name = status:match("^Name:%s*([^\r\n]+)")
        local state = status:match("\nState:%s*(%a)")
        local real, effective, saved, filesystem = status:match("\nUid:%s*(%d+)%s+(%d+)%s+(%d+)%s+(%d+)[ \t]*[\r\n]")
        if name ~= "stubby" or not state or not state:match("^[RSDITtWP]$") or not filesystem or
            tonumber(real) > 4294967294 or tonumber(effective) > 4294967294 or tonumber(saved) > 4294967294 or tonumber(filesystem) > 4294967294 then
            return unknown("Invalid Stubby process UID/state for PID " .. pid)
        end
        local after = instance(pid)
        if before ~= after then return unknown("Stubby process changed during observation") end
        local uid = tonumber(effective)
        if euid and euid ~= uid then mixed = true end
        euid = euid or uid
        processes[#processes + 1] = { pid = pid, euid = uid, instance = before }
    end
    if #processes == 0 then return unknown("Empty Stubby PID response") end
    return { state = mixed and "mixed" or euid == 0 and "root" or "user", processes = processes, process_count = #processes }
end

local function config()
    local text, err = SRV.read_file(CONFIG, LIB.UCI_MAX_SIZE)
    if not text then return unknown("Cannot read Stubby configuration: " .. tostring(err)) end
    local valid
    valid, err = LIB.validate_uci_config(text)
    if not valid then return unknown(err) end
    local statements
    statements, err = LIB.uci_statements(text, true)
    if not statements then return unknown(err) end
    local selected, seen, manual, addresses = false, false, "0", {}
    for _, statement in ipairs(statements) do
        local t = statement.tokens
        if t[1] == "config" then
            selected = t[2] == "stubby" and t[3] == "global"
            if selected and seen then return unknown("Duplicate Stubby global section") end
            seen = seen or selected
        elseif selected and (t[2] == "manual" or t[2] == "listen_address") then
            if #t ~= 3 then return unknown("Invalid Stubby listener/manual setting") end
            if t[2] == "manual" and t[1] == "option" then manual = t[3]
            elseif t[2] == "listen_address" and (t[1] == "option" or t[1] == "list") then
                if t[1] == "option" then addresses = {} end
                if #t[3] > 256 or #addresses >= 32 or t[3]:find("[%c]") then return unknown("Invalid or excessive Stubby listen addresses") end
                addresses[#addresses + 1] = t[3]
            else return unknown("Invalid Stubby listener/manual directive") end
        end
    end
    if not seen then return unknown("Missing Stubby global section") end
    manual = manual:lower()
    local enabled = ({ ["1"] = true, ["true"] = true, yes = true, on = true })[manual]
    local disabled = ({ ["0"] = true, ["false"] = true, no = true, off = true })[manual]
    if not enabled and not disabled then return unknown("Invalid Stubby manual setting") end
    return { state = enabled and "manual" or "uci", listen_addresses = addresses, listen_count = #addresses }
end

local function listeners(process)
    if process.state == "unknown" then return unknown("Socket ownership requires a known Stubby process snapshot") end
    if process.state == "stopped" then return { state = "none", entries = {}, count = 0 } end
    local ok, output = SRV.exec_checked(M.LISTENER_COMMAND)
    if not ok then return unknown("Cannot inspect listening sockets: " .. output) end
    if output:find("PT_STUBBY_NETSTAT_OVERFLOW", 1, true) then return unknown("Listening socket output exceeds 64 KiB\n" .. output) end
    local body, code = output:match("^(.*)\nPT_STUBBY_NETSTAT:(%d+)\n$")
    if not body or code ~= "0" then return unknown("Listening socket command failed or result is incomplete\n" .. output) end
    local pids, entries, header, unidentified = {}, {}, false, false
    for _, item in ipairs(process.processes) do pids[item.pid] = true end
    for line in body:gmatch("[^\r\n]+") do
        if line:match("^Proto%s+Recv%-Q%s+Send%-Q%s+Local Address") then header = true
        elseif line:match("^Active Internet connections") then -- table title
        elseif line:match("%S") then
            local fields = {}
            for token in line:gmatch("%S+") do fields[#fields + 1] = token end
            local proto = fields[1] and fields[1]:match("^(tcp)6?$") or fields[1] and fields[1]:match("^(udp)6?$")
            local expected = proto == "tcp" and 7 or 6
            if not header or not proto or #fields ~= expected or not fields[2]:match("^%d+$") or not fields[3]:match("^%d+$") or
                proto == "tcp" and fields[6] ~= "LISTEN" then return unknown("Unexpected listening socket table\n" .. output) end
            local pid, program = fields[#fields]:match("^(%d+)/(%S+)$")
            if not pid then
                if fields[#fields] ~= "-" then return unknown("Invalid listening socket owner\n" .. output) end
                unidentified = true
            elseif pids[pid] then
                local address, port = fields[4]:match("^([%x%.:]+):(%d+)$")
                port = tonumber(port)
                if program ~= "stubby" or not address or not port or port < 1 or port > 65535 or #entries >= 128 then
                    return unknown("Invalid or excessive Stubby listening socket rows\n" .. output)
                end
                entries[#entries + 1] = { protocol = proto, address = address, port = port, pid = pid }
            end
        end
    end
    if not header then return unknown("Missing listening socket table header\n" .. output) end
    if #entries == 0 and unidentified then return unknown("Listening socket owners are unavailable\n" .. output) end
    return { state = #entries > 0 and "observed" or "none", entries = entries, count = #entries }
end

function M.read()
    local source, err, errno = SRV.read_file(INIT, LIB.UCI_MAX_SIZE)
    local init
    if not source then init = errno == 2 and { state = "missing" } or unknown("Cannot read init script: " .. tostring(err))
    elseif not source:match("%S") then init = unknown("Init script is empty")
    else init = inspect_init(source) end
    local process = runtime()
    local sockets = listeners(process)
    for _, item in ipairs(process.processes or {}) do
        if instance(item.pid) ~= item.instance then
            process, sockets = unknown("Stubby process changed during observation"), unknown("Socket snapshot no longer matches the process")
            break
        end
    end
    local repairable = init.state == "literal" and init.user == "stubby"
    return {
        check_version = 2,
        -- Old clients fail closed on the new unknown enum; fixed never means
        -- root merely because a source substring is absent.
        status = init.state == "missing" and "not_installed" or process.state == "root" and "fixed" or "unknown",
        init = init, runtime = process, listeners = sockets, config = config(),
        repair = { available = repairable, reason = repairable and "Optional root-mode workaround; non-root operation is not itself an error" or
            init.state == "literal" and (init.user == "root" or init.user == "0") and "Init already declares root" or "No supported literal stubby user declaration to replace" }
    }
end

return M
