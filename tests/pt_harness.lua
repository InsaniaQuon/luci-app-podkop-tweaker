-- pt_harness | v1.0.0 | 23.08.2026 | Test harness: in-memory VFS overlay + luci.* fakes for busted (Lua 5.1)

local M = {}

local json = require("pt_json")
M.json = json

local ORIGINALS = {}
local ST = nil

local CLEAR_LOADED_IDS = {
    "podkop-tweaker.http", "podkop-tweaker.services", "podkop-tweaker.lib",
    "podkop-tweaker.diag", "podkop-tweaker.argon", "podkop-tweaker.subsched",
    "podkop-tweaker.bundle", "podkop-tweaker.api_diag", "podkop-tweaker.api_argon",
    "podkop-tweaker.api_stubby", "podkop-tweaker.api_podkop", "podkop-tweaker.api_subs",
    "podkop-tweaker.api_singbox", "podkop-tweaker.api_bundle", "podkop-tweaker.api_update",
    "pt-subs-lib", "luci.sys", "luci.model.uci", "luci.http",
    "luci.jsonc", "luci.json", "cjson", "nixio", "nixio.fs"
}

local PRELOAD_KEYS = { "luci.sys", "luci.model.uci", "luci.http", "luci.jsonc",
    "luci.json", "cjson", "nixio", "nixio.fs" }

local function save_original(name, val)
    if ORIGINALS[name] == nil then ORIGINALS[name] = val end
end

-- === fd emulation ===

local function make_fd(entry, mode)
    local fd = { _entry = entry, _pos = 1, _closed = false }
    local m1 = mode:sub(1, 1)
    if m1 == "w" then entry.content = "" end
    if m1 == "a" then fd._pos = #entry.content + 1 end

    function fd:read(fmt)
        if self._closed then return nil end
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
            if type(r.out) == "function" then return r.out(cmd) end
            return r.out or ""
        end
    end
    return ""
end

-- === fakes ===

local function make_sys(st)
    return {
        exec = function(cmd)
            table.insert(st.exec_log, cmd)
            return run_responders(st.sys_scripts, cmd)
        end
    }
end

local function make_uci(st)
    local db = st.uci
    local U = {}

    local function find_section(conf, name)
        local cfg = db[conf]
        if not cfg then return nil end
        for _, s in ipairs(cfg) do
            if s[".name"] == name then return s end
        end
        return nil
    end

    function U:get(conf, name, opt)
        local s = find_section(conf, name)
        if not s then return nil end
        if opt == nil then return s[".type"] end
        return s[opt]
    end

    function U:set(conf, name, a, b)
        local s = find_section(conf, name)
        if b == nil then
            if not s then
                s = { [".name"] = name, [".type"] = a }
                db[conf] = db[conf] or {}
                table.insert(db[conf], s)
            end
            return true
        end
        if not s then
            s = { [".name"] = name, [".type"] = "section" }
            db[conf] = db[conf] or {}
            table.insert(db[conf], s)
        end
        s[a] = b
        return true
    end

    function U:foreach(conf, typ, cb)
        local cfg = db[conf]
        if not cfg then return end
        for _, s in ipairs(cfg) do
            if s[".type"] == typ then cb(s) end
        end
    end

    function U:delete(conf, name, opt)
        local s = find_section(conf, name)
        if not s then return end
        if opt then s[opt] = nil end
    end

    function U:commit(conf)
        table.insert(st.commits, conf)
    end

    function U:save() return true end
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
        if vfs[path] then return { mtime = os.time(), is_directory = false } end
        if dirs[path] then return { mtime = os.time(), is_directory = true } end
        for p, d in pairs(dirs) do
            if d and path:sub(1, #p + 1) == p .. "/" then
                return { mtime = os.time(), is_directory = true }
            end
        end
        for p in pairs(vfs) do
            if p:sub(1, #path + 1) == path .. "/" then
                return { mtime = os.time(), is_directory = true }
            end
        end
        return nil
    end

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
            local m1 = mode:sub(1, 1)
            local e = st.vfs[path]
            if m1 == "r" then
                if not e then return nil, path .. ": No such file or directory" end
                return make_fd(e, "r")
            end
            if not e then
                e = { content = "" }
                st.vfs[path] = e
            end
            return make_fd(e, mode)
        end
        return ORIGINALS["io.open"](path, mode)
    end

    save_original("io.popen", io.popen)
    io.popen = function(cmd, mode)
        if st.active then
            table.insert(st.popen_log, cmd)
            local out = ""
            if type(st.popen_fn) == "function" then out = st.popen_fn(cmd) or "" end
            local e = { content = out }
            return make_fd(e, "r")
        end
        return ORIGINALS["io.popen"](cmd, mode)
    end

    save_original("os.execute", os.execute)
    os.execute = function(cmd)
        if st.active then
            table.insert(st.execute_log, cmd)
            return true, "exit", 0
        end
        return ORIGINALS["os.execute"](cmd)
    end

    save_original("os.rename", os.rename)
    os.rename = function(a, b)
        if st.active then
            table.insert(st.execute_log, "rename " .. a .. " -> " .. b)
            local e = st.vfs[a]
            if not e then return nil, "no entry" end
            st.vfs[b] = e
            st.vfs[a] = nil
            return true
        end
        return ORIGINALS["os.rename"](a, b)
    end

    save_original("os.remove", os.remove)
    os.remove = function(p)
        if st.active then
            table.insert(st.execute_log, "remove " .. tostring(p))
            if st.vfs[p] then st.vfs[p] = nil; return true end
            return nil, "no entry"
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
        sys_scripts = opts.sys or {},
        popen_fn = opts.popen,
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
    ST.active = false
    restore_wraps()
    remove_preloads()
    clear_loaded()
    ST = nil
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

function M.vfs_exists(path)
    return (ST and (ST.vfs[path] ~= nil or ST.dirs[path] ~= nil)) or false
end

function M.reload(modname)
    package.loaded[modname] = nil
    return require(modname)
end

return M
