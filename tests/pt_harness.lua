-- pt_harness | v1.1.0 | 17.10.2026 | In-memory native IO/owned-stage/lock model + LuCI fakes (Lua 5.1)
-- Failure keys are literal paths, or a literal prefix followed by one final *.
-- An exact rule wins; otherwise the longest matching prefix wins. No aliases:
-- failures["/config.tmp-write.*"] = { close = true } targets actual unique stages.
-- { mktemp = true } fails allocation by template OR next candidate path;
-- { mkdir = true } / { rmdir = true } explicitly fail an app lock operation.
-- H.allocations(pattern), H.stage_paths(pattern), H.last_stage(pattern) expose
-- successful mktemp allocations in order, even after publication/cleanup.
-- popen accepts a responder list like sys/execute, or the legacy function. In
-- strict callbacks, return nil for an unhandled command ("" is explicit output).
-- H.begin{strict=true} rejects unmatched critical commands and http.write(nil).
-- H.finish restores globals BEFORE reporting unexpected calls, so after_each
-- cannot lose failures swallowed by a production pcall. Legacy defaults remain.
-- cursor() remains an RPC-style fake: directory arguments are NOT supported.

local M = {}

local json = require("pt_json")
M.json = json

local ORIGINALS = {}
local ST = nil

local CLEAR_LOADED_IDS = {
    "podkop-tweaker.http", "podkop-tweaker.services", "podkop-tweaker.lib",
    "podkop-tweaker.diag", "podkop-tweaker.argon", "podkop-tweaker.subsched", "podkop-tweaker.theme", "podkop-tweaker.appearance",
    "podkop-tweaker.net", "podkop-tweaker.archive", "podkop-tweaker.dns_observation", "podkop-tweaker.web_restart",
    "podkop-tweaker.theme_packages", "podkop-tweaker.theme_config",
    "podkop-tweaker.bundle", "podkop-tweaker.api_diag", "podkop-tweaker.api_argon",
    "podkop-tweaker.api_stubby", "podkop-tweaker.api_podkop", "podkop-tweaker.api_subs",
    "podkop-tweaker.api_singbox", "podkop-tweaker.api_bundle", "podkop-tweaker.api_update",
    "pt-subs-lib", "pt-auto-update", "luci.sys", "luci.model.uci", "luci.http",
    "luci.jsonc", "luci.json", "cjson", "nixio", "nixio.fs"
}

local PRELOAD_KEYS = { "luci.sys", "luci.model.uci", "luci.http", "luci.jsonc",
    "luci.json", "cjson", "nixio", "nixio.fs" }

local function save_original(name, val)
    if ORIGINALS[name] == nil then ORIGINALS[name] = val end
end

local function path_matches(pattern, path)
    if type(pattern) ~= "string" or type(path) ~= "string" then return false end
    if pattern == path then return true end
    return pattern:sub(-1) == "*" and path:sub(1, #pattern - 1) == pattern:sub(1, -2)
end

local function failure_for(st, path)
    if not st or not path then return nil end
    if st.failures[path] ~= nil then return st.failures[path] end
    local found, length
    for pattern, failure in pairs(st.failures) do
        if type(pattern) == "string" and pattern:sub(-1) == "*" and path_matches(pattern, path) and (not length or #pattern > length) then
            found, length = failure, #pattern
        end
    end
    return found
end

local function unexpected(st, kind, command)
    local call = { kind = kind, command = command }
    st.unexpected[#st.unexpected + 1] = call
    return "Unexpected " .. kind .. ": " .. tostring(command)
end

local function critical_command(cmd)
    if cmd:find("PT_[A-Z_]*EXIT:") or cmd:find("/etc/init.d/", 1, true) or
        cmd:find("sing-box check", 1, true) or cmd:find("sh -n ", 1, true) then return true end
    for _, word in ipairs({ "mktemp", "mkdir", "rmdir", "chmod", "chown", "rm", "mv", "cp", "ln", "touch", "tee", "truncate", "install", "flock" }) do
        if cmd:find("%f[%w]" .. word .. "%f[^%w%-]") then return true end
    end
    return false
end

-- === fd emulation ===

local function make_fd(entry, mode, path, st)
    local fd = { _entry = entry, _pos = 1, _closed = false }
    local m1 = mode:sub(1, 1)
    if m1 == "w" then entry.content = "" end
    if m1 == "a" then fd._pos = #entry.content + 1 end

    function fd:read(fmt)
        if self._closed then return nil end
        local failure = failure_for(st, path)
        if entry.read_error or failure and failure.read then return nil, "Injected read failure", 5 end
        if fmt == nil or fmt == "*l" or fmt == "l" then
            local c = entry.content
            if self._pos > #c then return nil end
            local nl = c:find("\n", self._pos, true)
            local line
            if nl then
                line = c:sub(self._pos, nl - 1)
                self._pos = nl + 1
            else
                line = c:sub(self._pos)
                self._pos = #c + 1
            end
            return (line:gsub("\r$", ""))
        elseif fmt == "*a" or fmt == "a" then
            local c = entry.content
            if self._pos > #c then return "" end
            local rest = c:sub(self._pos)
            self._pos = #c + 1
            return rest
        elseif type(fmt) == "number" then
            local c = entry.content
            if self._pos > #c then return nil end
            local chunk = c:sub(self._pos, self._pos + fmt - 1)
            self._pos = self._pos + #chunk
            return chunk
        end
        return nil
    end

    function fd:lines()
        return function()
            return self:read("*l")
        end
    end

    function fd:write(...)
        if self._closed then return nil end
        local strs = {}
        for i = 1, select("#", ...) do strs[#strs + 1] = tostring(select(i, ...)) end
        local s = table.concat(strs)
        if st then table.insert(st.io_log, { operation = "write", path = path, size = #s, mode = entry.mode }) end
        local failure = failure_for(st, path)
        if failure and failure.write then
            if failure.partial then entry.content = s:sub(1, failure.partial) end
            return nil, "Injected write failure", 28
        end
        local head = entry.content:sub(1, self._pos - 1)
        entry.content = head .. s
        self._pos = #entry.content + 1
        return self
    end

    function fd:seek(whence, off)
        if self._closed then return nil end
        whence = whence or "cur"
        off = off or 0
        local len = #entry.content
        if whence == "set" then self._pos = off + 1
        elseif whence == "cur" then self._pos = self._pos + off
        elseif whence == "end" then self._pos = len + 1 end
        if self._pos < 1 then self._pos = 1 end
        if self._pos > len + 1 then self._pos = len + 1 end
        return self._pos - 1
    end

    function fd:close()
        self._closed = true
        if st then table.insert(st.io_log, { operation = "close", path = path }) end
        local failure = failure_for(st, path)
        if entry.close_error or failure and failure.close then return nil, "Injected close failure", 5 end
        return true
    end

    return fd
end

-- === responders ===

local function run_responders(list, cmd)
    for _, r in ipairs(list) do
        local hit = false
        if type(r.match) == "function" then
            hit = r.match(cmd)
        elseif type(r.match) == "string" then
            hit = cmd:find(r.match, 1, true) ~= nil
        end
        if hit then
            if type(r.out) == "function" then return r.out(cmd), true end
            return r.out == nil and "" or r.out, true
        end
    end
    return ""
end

-- These are exact internal command primitives, not a general shell interpreter.
-- Parse shell_escape's single-quoted word, including an embedded apostrophe.
local function shell_word(word)
    if word:sub(1, 1) ~= "'" then return word:match("^[/%w%._%-]+$") end
    local parts, at = {}, 1
    while at <= #word do
        if word:sub(at, at) ~= "'" then return nil end
        local last = word:find("'", at + 1, true)
        if not last then return nil end
        parts[#parts + 1] = word:sub(at + 1, last - 1)
        at = last + 1
        if at <= #word then
            if word:sub(at, at + 1) ~= "\\'" or word:sub(at + 2, at + 2) ~= "'" then return nil end
            parts[#parts + 1], at = "'", at + 2
        end
    end
    return table.concat(parts)
end

local CHECKED_END = ") </dev/null 2>&1; printf '\\nPT_EXIT:%s\\n' \"$?\""
local MKTEMP_START = "umask 077; mktemp "
local MKTEMP_END = " 2>&1; printf '\\nPT_MKTEMP_EXIT:%s\\n' \"$?\""

local function checked_body(cmd)
    if cmd:sub(1, 1) == "(" and cmd:sub(-#CHECKED_END) == CHECKED_END then
        return cmd:sub(2, #cmd - #CHECKED_END), true
    end
    return cmd, false
end

local function mktemp_output(st, cmd)
    if cmd:sub(1, #MKTEMP_START) ~= MKTEMP_START or cmd:sub(-#MKTEMP_END) ~= MKTEMP_END then return nil end
    local word = cmd:sub(#MKTEMP_START + 1, #cmd - #MKTEMP_END)
    if word:sub(1, 1) ~= "'" then return nil end
    local template = shell_word(word)
    if not template or template:sub(1, 1) ~= "/" or template:sub(-7) ~= ".XXXXXX" then return nil end
    local path
    repeat
        st.mktemp_counter = st.mktemp_counter + 1
        path = template:sub(1, -7) .. string.format("%06d", st.mktemp_counter)
    until not st.vfs[path] and not st.dirs[path]
    local by_template, by_path = failure_for(st, template), failure_for(st, path)
    local flag = by_template and by_template.mktemp or by_path and by_path.mktemp
    if flag then
        local code = type(flag) == "number" and flag or 1
        st.io_log[#st.io_log + 1] = { operation = "mktemp", template = template, path = path, success = false }
        return "mktemp: Injected allocation failure\n\nPT_MKTEMP_EXIT:" .. code .. "\n"
    end
    -- Allocation reserves a NEW file with mode 600 before the caller opens it.
    st.vfs[path] = { content = "", mode = "600" }
    local allocation = { path = path, template = template, command = cmd, mode = "600", success = true }
    st.allocations[#st.allocations + 1] = allocation
    st.io_log[#st.io_log + 1] = { operation = "mktemp", path = path, template = template, mode = "600", success = true }
    return path .. "\n\nPT_MKTEMP_EXIT:0\n"
end

local function app_lock(path)
    return path == "/var/lock/podkop-fragment.lock" or
        path:match("^/var/lock/podkop%-tweaker%-[a-zA-Z0-9_%-]+%.lock$") ~= nil
end

local function command_primitive(cmd)
    local body, checked = checked_body(cmd)
    for _, ending in ipairs({ " 2>/dev/null", " 2>&1" }) do
        if body:sub(-#ending) == ending then body = body:sub(1, #body - #ending); break end
    end
    local verb, args = body:match("^(%a+) (.+)$")
    if verb == "mkdir" or verb == "rmdir" then
        if args:sub(1, 3) == "-- " then args = args:sub(4) end
        local path = shell_word(args)
        if path and app_lock(path) then return { operation = verb, path = path, checked = checked } end
    elseif verb == "chmod" then
        local mode, word = args:match("^([0-7][0-7][0-7]) (.+)$")
        if not mode then word = args:match("^%+x (.+)$"); mode = word and "+x" end
        local path = word and shell_word(word)
        if path and path:sub(1, 1) == "/" then
            return { operation = verb, path = path, mode = mode, checked = checked }
        end
    end
end

local function response_code(response, transport)
    if type(response) == "number" then return response end
    if response == false then return 1 end
    if transport == "exec" and type(response) == "string" then
        return tonumber(response:match("\nPT_EXIT:(%d+)\n$"))
    end
end

local function modeled_command(st, cmd, scripts, transport)
    local primitive = command_primitive(cmd)
    if not primitive then return nil, false end
    local op, path = primitive.operation, primitive.path
    -- Snapshot existence before observers: a broad 'return 0' must never make
    -- an already-held directory lock reacquirable or an absent lock removable.
    local existed = st.dirs[path] or st.vfs[path]
    local response, matched = run_responders(scripts, cmd)
    local mock_code = matched and response_code(response, transport)
    local failure = failure_for(st, path)
    local flag = failure and failure[op]
    local code, details = 0, ""
    if flag then
        code, details = type(flag) == "number" and flag or 1, "Injected " .. op .. " failure"
    elseif mock_code and mock_code ~= 0 then
        code = mock_code
        details = type(response) == "string" and response:match("^(.*)\nPT_EXIT:%d+\n$") or "Injected " .. op .. " command failure"
    elseif op == "mkdir" and (existed or st.dirs[path] or st.vfs[path]) then
        code, details = 1, "mkdir: File exists: " .. path
    elseif op == "rmdir" then
        if not existed or not st.dirs[path] then code, details = 1, "rmdir: No such directory: " .. path end
        for child in pairs(st.vfs) do
            if child:sub(1, #path + 1) == path .. "/" then code, details = 1, "rmdir: Directory not empty: " .. path end
        end
        for child in pairs(st.dirs) do
            if child:sub(1, #path + 1) == path .. "/" then code, details = 1, "rmdir: Directory not empty: " .. path end
        end
    elseif op == "chmod" and not st.vfs[path] and not st.dirs[path] then
        code, details = 1, "chmod: No such file: " .. path
    end
    if code == 0 then
        if op == "mkdir" then st.dirs[path] = true
        elseif op == "rmdir" then st.dirs[path] = nil
        elseif st.vfs[path] then
            local mode = primitive.mode
            if mode == "+x" then
                mode = (st.vfs[path].mode or "644"):gsub("%d", function(digit)
                    local n = tonumber(digit)
                    return tostring(n % 2 == 0 and n + 1 or n)
                end)
            end
            st.vfs[path].mode = mode
        end
    end
    st.io_log[#st.io_log + 1] = { operation = op, path = path, mode = primitive.mode, success = code == 0 }
    if transport == "execute" then return code, true end
    if primitive.checked then return details .. "\nPT_EXIT:" .. code .. "\n", true end
    return details, true
end

-- === fakes ===

local function make_sys(st)
    return {
        exec = function(cmd)
            table.insert(st.exec_log, cmd)
            local native, modeled = modeled_command(st, cmd, st.sys_scripts, "exec")
            if modeled then return native end
            local output, matched = run_responders(st.sys_scripts, cmd)
            if not matched and st.strict and critical_command(cmd) then
                return unexpected(st, "sys.exec", cmd) .. "\nPT_EXIT:125\n"
            end
            if not matched and cmd:find("PT_EXIT:", 1, true) then return "\nPT_EXIT:0\n" end
            return output
        end
    }
end

local function make_uci(st)
    local db = st.uci
    local U = {}

    -- Explicit fixture failures are independent of cursor directory arguments.
    -- uci_failures = { argon = { set = true, commit = true } }.
    local function fails(operation, conf)
        local failure = st.uci_failures[conf]
        return failure and failure[operation]
    end

    local function find_section(conf, name)
        local cfg = db[conf]
        if not cfg then return nil end
        for _, s in ipairs(cfg) do
            if s[".name"] == name then return s end
        end
        return nil
    end

    function U:get(conf, name, opt)
        if fails("get", conf) then return nil, "Injected UCI get failure" end
        local s = find_section(conf, name)
        if not s then return nil end
        if opt == nil then return s[".type"] end
        return s[opt]
    end

    function U:set(conf, name, a, b)
        if fails("set", conf) then return false, "Injected UCI set failure" end
        local s = find_section(conf, name)
        if b == nil then
            if not s then
                s = { [".name"] = name, [".type"] = a }
                db[conf] = db[conf] or {}
                table.insert(db[conf], s)
            else s[".type"] = a end
            return true
        end
        if not s then
            if st.strict then return false, "Section not found" end
            s = { [".name"] = name, [".type"] = "section" }
            db[conf] = db[conf] or {}
            table.insert(db[conf], s)
        end
        s[a] = b
        return true
    end

    function U:foreach(conf, typ, cb)
        if fails("foreach", conf) then return false, "Injected UCI foreach failure" end
        local cfg = db[conf]
        if not cfg then return false end
        for _, s in ipairs(cfg) do
            if (typ == nil or s[".type"] == typ) and cb(s) == false then break end
        end
        return true
    end

    function U:delete(conf, name, opt)
        if fails("delete", conf) then return false, "Injected UCI delete failure" end
        local s = find_section(conf, name)
        if not s then return false end
        if opt then
            if s[opt] == nil then return false end
            s[opt] = nil
        else
            for i, entry in ipairs(db[conf]) do
                if entry == s then table.remove(db[conf], i); break end
            end
        end
        return true
    end

    function U:commit(conf)
        table.insert(st.commits, conf)
        if fails("commit", conf) then return false, "Injected UCI commit failure" end
        if st.strict and not db[conf] then return false, "Configuration not found" end
        return true
    end

    function U:save(conf)
        if fails("save", conf) then return false, "Injected UCI save failure" end
        if st.strict and conf and not db[conf] then return false, "Configuration not found" end
        return true
    end
    function U:revert() return true end
    function U:unload() return true end
    function U:get_state(conf, name, opt) return U:get(conf, name, opt) end

    return { cursor = function() return U end }
end

local function make_http(st)
    local H = {
        _headers = {},
        _prepared = {},
        _status = {},
        _body = {},
        _json = nil,
        _redirects = {}
    }

    function H.formvalue(name)
        return st.fv[name]
    end

    function H.getenv(key)
        return st.env[key]
    end

    function H.prepare_content(t)
        table.insert(H._prepared, t)
    end

    function H.header(k, v)
        H._headers[k] = v
        table.insert(H._headers, { k, v })
    end

    function H.status(code, msg)
        table.insert(H._status, { code = code, msg = msg })
    end

    function H.write(s)
        if st.strict and s == nil then error(unexpected(st, "http.write", "nil body"), 2) end
        table.insert(H._body, tostring(s))
    end

    function H.write_json(t)
        H._json = t
        table.insert(H._body, json.stringify(t))
    end

    function H.close() return true end

    function H.redirect(url)
        table.insert(H._redirects, url)
    end

    function H.content() return table.concat(H._body) end

    return H
end

local function make_nixio_fs(vfs, dirs)
    local fs = {}

    function fs.stat(path)
        if vfs[path] then return { mtime = os.time(), is_directory = false, type = vfs[path].type or "reg", size = #vfs[path].content } end
        if dirs[path] then return { mtime = os.time(), is_directory = true, type = "dir" } end
        for p, d in pairs(dirs) do
            if d and path:sub(1, #p + 1) == p .. "/" then
                return { mtime = os.time(), is_directory = true, type = "dir" }
            end
        end
        for p in pairs(vfs) do
            if p:sub(1, #path + 1) == path .. "/" then
                return { mtime = os.time(), is_directory = true, type = "dir" }
            end
        end
        return nil
    end
    fs.lstat = fs.stat

    function fs.readfile(path)
        local e = vfs[path]
        if not e then return nil end
        return e.content
    end

    function fs.unlink(path)
        if vfs[path] then vfs[path] = nil; return true end
        return false
    end

    function fs.mkdir(path) dirs[path] = true; return true end
    fs.mkdirr = fs.mkdir

    return fs
end

-- === global wraps ===

local function install_wraps(st)
    save_original("io.open", io.open)
    io.open = function(path, mode)
        if st.active and type(path) == "string" and path:sub(1, 1) == "/" then
            mode = mode or "r"
            table.insert(st.io_log, { operation = "open", path = path, mode = mode })
            local failure = failure_for(st, path)
            if failure and failure.open then return nil, "Injected open failure", failure.errno or 13 end
            local m1 = mode:sub(1, 1)
            local e = st.vfs[path]
            if m1 == "r" then
                if not e then return nil, path .. ": No such file or directory", 2 end
                return make_fd(e, "r", path, st)
            end
            if not e then
                e = { content = "" }
                st.vfs[path] = e
            end
            return make_fd(e, mode, path, st)
        end
        return ORIGINALS["io.open"](path, mode)
    end

    save_original("io.popen", io.popen)
    io.popen = function(cmd, mode)
        if st.active then
            table.insert(st.popen_log, cmd)
            -- Known allocation MUST win over broad network/CLI callbacks which
            -- historically return "" for every command they do not understand.
            local out, matched = mktemp_output(st, cmd), false
            if out ~= nil then matched = true
            else
                out, matched = modeled_command(st, cmd, st.popen_scripts, "exec")
                if not matched then
                    if type(st.popen_fn) == "function" then
                        out = st.popen_fn(cmd)
                        matched = out ~= nil
                    else out, matched = run_responders(st.popen_scripts, cmd) end
                end
            end
            if not matched and st.strict and critical_command(cmd) then
                out = unexpected(st, "io.popen", cmd) .. "\nPT_EXIT:125\n"
            end
            out = out or ""
            local e = type(out) == "table" and out or { content = out }
            return make_fd(e, "r")
        end
        return ORIGINALS["io.popen"](cmd, mode)
    end

    save_original("os.execute", os.execute)
    os.execute = function(cmd)
        if st.active then
            table.insert(st.execute_log, cmd)
            local native, modeled = modeled_command(st, cmd, st.execute_scripts, "execute")
            if modeled then return native end
            local response, matched = run_responders(st.execute_scripts, cmd)
            if st.strict and critical_command(cmd) and
                (not matched or type(response) ~= "number" and type(response) ~= "boolean") then
                unexpected(st, "os.execute", cmd)
                return 125
            end
            if response ~= "" then return response end
            return true, "exit", 0
        end
        return ORIGINALS["os.execute"](cmd)
    end

    save_original("os.rename", os.rename)
    os.rename = function(a, b)
        if st.active then
            table.insert(st.execute_log, "rename " .. a .. " -> " .. b)
            local event = { operation = "rename", path = a, target = b, success = false }
            st.io_log[#st.io_log + 1] = event
            local failure = failure_for(st, b) or failure_for(st, a)
            if failure and failure.rename then return nil, "Injected rename failure", 5 end
            local e = st.vfs[a]
            if not e then return nil, "no entry", 2 end
            st.vfs[b] = e
            st.vfs[a] = nil
            event.success, event.content = true, e.content
            return true
        end
        return ORIGINALS["os.rename"](a, b)
    end

    save_original("os.remove", os.remove)
    os.remove = function(p)
        if st.active then
            table.insert(st.execute_log, "remove " .. tostring(p))
            local event = { operation = "remove", path = p, success = false }
            st.io_log[#st.io_log + 1] = event
            local failure = failure_for(st, p)
            if failure and failure.remove then return nil, "Injected remove failure", 5 end
            if st.vfs[p] then st.vfs[p] = nil; event.success = true; return true end
            return nil, "no entry", 2
        end
        return ORIGINALS["os.remove"](p)
    end
end

local function restore_wraps()
    if ORIGINALS["io.open"] then io.open = ORIGINALS["io.open"] end
    if ORIGINALS["io.popen"] then io.popen = ORIGINALS["io.popen"] end
    if ORIGINALS["os.execute"] then os.execute = ORIGINALS["os.execute"] end
    if ORIGINALS["os.rename"] then os.rename = ORIGINALS["os.rename"] end
    if ORIGINALS["os.remove"] then os.remove = ORIGINALS["os.remove"] end
    _G.luci = ORIGINALS["global_luci"]
end

local function install_preloads(st)
    package.preload["luci.sys"] = function() return make_sys(st) end
    package.preload["luci.model.uci"] = function() return make_uci(st) end
    package.preload["luci.http"] = function() return st.http end
    package.preload["nixio"] = function() return { fs = make_nixio_fs(st.vfs, st.dirs) } end
    package.preload["nixio.fs"] = function() return make_nixio_fs(st.vfs, st.dirs) end
    package.preload["luci.jsonc"] = function()
        return { parse = json.parse, stringify = json.stringify }
    end
    package.preload["luci.json"] = function()
        return { parse = function(_) return st.legacy_json end }
    end
    -- legacy global luci.json referenced by some handlers (not require-based)
    save_original("global_luci", _G.luci)
    _G.luci = {
        json = { parse = function(_) return st.legacy_json end }
    }
    package.preload["cjson"] = function()
        return { decode = function(s)
            if st.cjson_fn then return st.cjson_fn(s) end
            return nil
        end }
    end
end

local function remove_preloads()
    for _, k in ipairs(PRELOAD_KEYS) do package.preload[k] = nil end
end

local function clear_loaded()
    for _, id in ipairs(CLEAR_LOADED_IDS) do package.loaded[id] = nil end
end

-- === public API ===

function M.sec(name, typ, opts)
    local s = { [".name"] = name, [".type"] = typ }
    if opts then
        for k, v in pairs(opts) do s[k] = v end
    end
    return s
end

function M.begin(opts)
    opts = opts or {}
    if ST then M.finish() end
    ST = {
        active = true,
        vfs = {}, dirs = {},
        fv = opts.fv or {}, env = opts.env or {},
        uci = opts.uci or {},
        uci_failures = opts.uci_failures or {},
        sys_scripts = opts.sys or {},
        execute_scripts = opts.execute or {}, failures = opts.failures or {}, io_log = {},
        popen_fn = type(opts.popen) == "function" and opts.popen or nil,
        popen_scripts = type(opts.popen) == "table" and opts.popen or {},
        strict = opts.strict == true, unexpected = {}, allocations = {}, mktemp_counter = 0,
        legacy_json = opts.legacy_json,
        cjson_fn = opts.cjson,
        exec_log = {}, popen_log = {}, execute_log = {},
        commits = {}
    }
    ST.http = make_http(ST)
    install_wraps(ST)
    install_preloads(ST)
    clear_loaded()
    return ST
end

function M.finish()
    if not ST then return end
    local finished = ST
    ST.active = false
    restore_wraps()
    remove_preloads()
    clear_loaded()
    ST = nil
    if finished.strict then M.assert_no_unexpected(finished) end
end

function M.assert_no_unexpected(state)
    state = state or ST
    if not state or #state.unexpected == 0 then return end
    local messages = {}
    for _, call in ipairs(state.unexpected) do
        messages[#messages + 1] = call.kind .. ": " .. tostring(call.command)
    end
    error("Unexpected harness calls:\n" .. table.concat(messages, "\n"), 2)
end

function M.state()
    return ST
end

function M.http()
    return ST and ST.http
end

function M.last_json()
    return ST and ST.http and ST.http._json or nil
end

function M.body()
    return ST and ST.http and ST.http.content() or ""
end

function M.exec_cmds()
    return ST and ST.exec_log or {}
end

function M.execute_cmds()
    return ST and ST.execute_log or {}
end

function M.popen_cmds()
    return ST and ST.popen_log or {}
end

function M.commits()
    return ST and ST.commits or {}
end

function M.vfs_read(path)
    local e = ST and ST.vfs[path]
    return e and e.content or nil
end

function M.vfs_write(path, content)
    if ST then ST.vfs[path] = { content = content } end
end

function M.vfs_mode(path)
    local entry = ST and ST.vfs[path]
    return entry and entry.mode
end

function M.vfs_mkdir(path)
    if ST then ST.dirs[path] = true end
end

function M.vfs_exists(path)
    return (ST and (ST.vfs[path] ~= nil or ST.dirs[path] ~= nil)) or false
end

function M.allocations(pattern)
    local allocations = {}
    for _, allocation in ipairs(ST and ST.allocations or {}) do
        if not pattern or path_matches(pattern, allocation.path) then
            allocations[#allocations + 1] = allocation
        end
    end
    return allocations
end

function M.stage_paths(pattern)
    local paths = {}
    for _, allocation in ipairs(M.allocations(pattern)) do paths[#paths + 1] = allocation.path end
    return paths
end

function M.last_stage(pattern)
    local paths = M.stage_paths(pattern)
    return paths[#paths]
end

function M.reload(modname)
    package.loaded[modname] = nil
    return require(modname)
end

return M
