-- Raw configuration reads: strict sing-box GET and legacy helper compatibility, in memory only.
package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path

local H = require("pt_harness")
local CTRL = "luci.controller.podkop-tweaker"
local CFG = "/etc/sing-box/config.json"
local BAK = CFG .. ".auto-backup"
local LEGACY = "/etc/config/stubby"
local SINGBOX_LIMIT = 2097152
local LEGACY_LIMIT = 8388608

local function files()
    local result = {}
    for path, entry in pairs(H.state().vfs) do result[path] = entry.content end
    return result
end

local function begin_read(path, content, failures)
    H.begin({ env = { REQUEST_METHOD = "GET" }, failures = failures })
    H.vfs_write(BAK, "previous known-good configuration")
    H.vfs_write("/etc/config/podkop-tweaker", "config settings 'settings'\n\toption show_argon_tab '0'\n")
    if content ~= nil then H.vfs_write(path, content) end
    local run = { before = files(), path = path, writes = {}, handles = {}, reads = {}, bytes = 0 }

    -- The shared fake stringifies nil; fail at the actual HTTP boundary instead.
    local http = H.http()
    local write = http.write
    http.write = function(value)
        assert.equal("string", type(value), "HTTP must never receive nil or a non-text configuration body")
        run.writes[#run.writes + 1] = value
        return write(value)
    end

    -- Observe the real VFS file handle without replacing read_stream or the handler.
    local open = io.open
    io.open = function(name, mode)
        local fd, err, errno = open(name, mode)
        if fd and name == path then
            run.handles[#run.handles + 1] = fd
            local read = fd.read
            fd.read = function(self, amount)
                local data, read_err, read_errno = read(self, amount)
                local size = type(data) == "string" and #data or 0
                run.reads[#run.reads + 1] = { amount = amount, size = size }
                run.bytes = run.bytes + size
                return data, read_err, read_errno
            end
        end
        return fd, err, errno
    end
    return run
end

local function assert_read_only(run)
    assert.same(run.before, files(), "GET must preserve the live config, backups and unrelated settings")
    assert.same({}, H.state().dirs)
    assert.same({}, H.state().uci)
    assert.same({}, H.commits())
    assert.same({}, H.exec_cmds())
    assert.same({}, H.execute_cmds())
    assert.same({}, H.popen_cmds())
    for _, operation in ipairs(H.state().io_log) do
        assert.not_equal("write", operation.operation)
        if operation.operation == "open" then assert.matches("^r", operation.mode) end
    end
end

local function assert_transport(run, status, content_type)
    local http = H.http()
    assert.is_true(#http._status <= 1)
    assert.equal(status, http._status[1] and http._status[1].code or 200)
    assert.same({ content_type }, http._prepared)
    assert.equal("no-cache, no-store, must-revalidate", http._headers["Cache-Control"])
    assert.equal("no-cache", http._headers.Pragma)
    assert.equal("0", http._headers.Expires)
    assert.is_nil(http._headers["Content-Disposition"])
    assert_read_only(run)
end

local function assert_text(run, body)
    assert_transport(run, 200, "text/plain")
    assert.is_nil(H.last_json(), "raw editor reads must not become a JSON envelope")
    assert.same({ body }, run.writes)
    assert.equal(body, H.body())
end

local function assert_json_error(run, status)
    assert_transport(run, status, "application/json")
    assert.same({}, run.writes, "errors must not write a nil, empty or partial raw configuration")
    local response = H.last_json()
    assert.is_table(response)
    assert.equal("string", type(response.error))
    assert.not_equal("", response.error)
    assert.equal("string", type(response.details))
    assert.not_equal("", response.details)
    assert.same(response, H.json.parse(H.body()))
    return response
end

local function assert_closed(run, expected)
    assert.equal(expected, #run.handles)
    for _, fd in ipairs(run.handles) do assert.is_true(fd._closed) end
    local closes = 0
    for _, operation in ipairs(H.state().io_log) do
        if operation.operation == "close" and operation.path == run.path then closes = closes + 1 end
    end
    assert.equal(expected, closes, "every opened configuration handle must be closed exactly once, including on errors")
end

local function assert_bounded(run, limit)
    local bytes = 0
    for _, read in ipairs(run.reads) do
        assert.equal("number", type(read.amount), "configuration reads must use a numeric byte bound, never *a")
        assert.is_true(read.amount > 0)
        assert.is_true(read.amount <= limit - bytes + 1, "allow at most one look-ahead byte beyond the configured cap")
        assert.is_true(read.size <= read.amount)
        bytes = bytes + read.size
        assert.is_true(bytes <= limit + 1)
    end
    assert.equal(bytes, run.bytes)
end

local function singbox_get()
    package.loaded[CTRL] = nil
    require(CTRL).api_read_singbox_config()
end

local function legacy_read()
    require("podkop-tweaker.http").send_text_file(LEGACY)
end

local function io_error_cases(path, read_config, limit)
    for _, case in ipairs({
        { name = "permission-denied open", failure = { open = true, errno = 13 }, opened = 0,
            error = "Cannot read configuration file", details = "Injected open failure" },
        { name = "non-ENOENT open error", failure = { open = true, errno = 5 }, opened = 0,
            error = "Cannot read configuration file", details = "Injected open failure" },
        { name = "read error", failure = { read = true }, opened = 1,
            error = "Cannot read configuration file", details = "Cannot read: Injected read failure" },
        { name = "close error", failure = { close = true }, opened = 1,
            error = "Cannot close configuration file", details = "Injected close failure" }
    }) do
        it("returns HTTP 500 JSON for " .. case.name .. " without writing a raw body", function()
            local run = begin_read(path, '{"outbounds":[]}\n', { [path] = case.failure })
            read_config()
            assert.same({ error = case.error, details = case.details }, assert_json_error(run, 500))
            assert_closed(run, case.opened)
            assert_bounded(run, limit)
        end)
    end
end

after_each(function()
    H.finish()
    package.loaded[CTRL] = nil
end)

describe("raw sing-box configuration GET", function()
    it("returns the exact text/plain body with no-cache headers and no mutation", function()
        local content = " \r\n{\n  \"outbounds\": [{\"type\":\"direct\",\"tag\":\"direct\"}],\n  \"route\": {\"final\":\"direct\"}\n}\n\t"
        local run = begin_read(CFG, content)
        singbox_get()
        assert_text(run, content)
        assert_closed(run, 1)
        assert_bounded(run, SINGBOX_LIMIT)
    end)

    for _, case in ipairs({ { name = "zero-byte", content = "" }, { name = "whitespace-only", content = " \t\r\n \n" } }) do
        it("returns HTTP 409 JSON for a " .. case.name .. " file instead of an empty success", function()
            local run = begin_read(CFG, case.content)
            singbox_get()
            local response = assert_json_error(run, 409)
            assert.equal("Configuration file is empty", response.error)
            assert.truthy(response.details:find(CFG, 1, true))
            assert_closed(run, 1)
            assert_bounded(run, SINGBOX_LIMIT)
        end)
    end

    it("returns HTTP 404 JSON when the configuration is missing without creating it", function()
        local run = begin_read(CFG)
        singbox_get()
        local response = assert_json_error(run, 404)
        assert.equal("Configuration file not found", response.error)
        assert.equal(CFG, response.details)
        assert_closed(run, 0)
    end)

    it("accepts the exact 2 MiB boundary without truncating the response", function()
        local content = '{"padding":"' .. string.rep("x", SINGBOX_LIMIT - #'{"padding":""}') .. '"}'
        assert.equal(SINGBOX_LIMIT, #content)
        local run = begin_read(CFG, content)
        singbox_get()
        assert_text(run, content)
        assert_closed(run, 1)
        assert_bounded(run, SINGBOX_LIMIT)
    end)

    it("rejects oversized input as an IO error after at most 2 MiB plus one byte and closes the file", function()
        local run = begin_read(CFG, string.rep("x", SINGBOX_LIMIT + 65536))
        singbox_get()
        local response = assert_json_error(run, 500)
        assert.equal("Cannot read configuration file", response.error)
        assert.equal("Content exceeds size limit", response.details)
        assert.equal(SINGBOX_LIMIT + 1, run.bytes)
        assert_bounded(run, SINGBOX_LIMIT)
        assert_closed(run, 1)
    end)

    io_error_cases(CFG, singbox_get, SINGBOX_LIMIT)
end)

describe("legacy send_text_file defaults", function()
    for _, case in ipairs({
        { name = "missing", opened = 0 },
        { name = "empty", content = "", opened = 1 },
        { name = "whitespace-only", content = " \t\r\n", opened = 1 }
    }) do
        it("keeps HTTP 200 text/plain for a " .. case.name .. " file without strict options", function()
            local run = begin_read(LEGACY, case.content)
            legacy_read()
            assert_text(run, case.content or "")
            assert_closed(run, case.opened)
            assert_bounded(run, LEGACY_LIMIT)
        end)
    end

    it("does not impose the sing-box-specific 2 MiB limit on generic callers", function()
        local content = string.rep("x", SINGBOX_LIMIT + 1)
        local run = begin_read(LEGACY, content)
        legacy_read()
        assert_text(run, content)
        assert_closed(run, 1)
        assert_bounded(run, LEGACY_LIMIT)
    end)

    io_error_cases(LEGACY, legacy_read, LEGACY_LIMIT)
end)
