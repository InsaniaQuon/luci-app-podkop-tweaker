-- BK1: complete bounded IO before attachment transport, memory-only fixtures.
package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path

local H = require("pt_harness")
local PATH = "/etc/config/podkop.auto-backup"
local LIMIT = 8388608

local function begin_download(path, content, failures)
    H.begin({ strict = true, failures = failures, env = { REQUEST_METHOD = "GET" } })
    if content ~= nil then H.vfs_write(path, content) end
    local run = { path = path, content = content, handles = {}, reads = {}, bytes = 0, writes = {} }
    local open = io.open
    io.open = function(name, mode)
        local fd, err, errno = open(name, mode)
        if fd and name == path then
            run.handles[#run.handles + 1] = fd
            local read, calls = fd.read, 0
            fd.read = function(self, amount)
                assert.equal("number", type(amount), "download IO must never use an unbounded *a read")
                assert.is_true(amount > 0 and amount <= LIMIT - run.bytes + 1)
                calls = calls + 1
                local data, read_err, read_errno
                if run.fail_after and calls > run.fail_after then
                    data, read_err, read_errno = nil, "Injected late read failure", 5
                else
                    data, read_err, read_errno = read(self, amount)
                end
                local size = type(data) == "string" and #data or 0
                run.reads[#run.reads + 1] = { amount = amount, size = size }
                run.bytes = run.bytes + size
                assert.is_true(run.bytes <= LIMIT + 1)
                return data, read_err, read_errno
            end
        end
        return fd, err, errno
    end
    local http = H.http()
    local prepare, header, write = http.prepare_content, http.header, http.write
    local function all_closed()
        for _, fd in ipairs(run.handles) do assert.is_true(fd._closed, "attachment transport started before the file was closed") end
    end
    http.prepare_content = function(kind)
        if kind == "application/octet-stream" then all_closed() end
        return prepare(kind)
    end
    http.header = function(key, value)
        if key == "Content-Disposition" then all_closed() end
        return header(key, value)
    end
    http.write = function(value)
        assert.equal("string", type(value), "HTTP must not stringify a failed nil read")
        all_closed()
        run.writes[#run.writes + 1] = value
        return write(value)
    end
    return run
end

local function assert_transport(run, status, kind)
    local http = H.http()
    assert.equal(status, http._status[1] and http._status[1].code or 200)
    assert.same({ kind }, http._prepared)
    assert.equal("no-cache, no-store, must-revalidate", http._headers["Cache-Control"])
    assert.equal("no-cache", http._headers.Pragma)
    assert.equal("0", http._headers.Expires)
    assert.equal(run.content, H.vfs_read(run.path), "a download must not change its source")
    assert.same({}, H.exec_cmds())
    assert.same({}, H.execute_cmds())
    assert.same({}, H.popen_cmds())
    local closes = 0
    for _, op in ipairs(H.state().io_log) do
        assert.not_equal("write", op.operation)
        if op.operation == "close" and op.path == run.path then closes = closes + 1 end
    end
    assert.equal(#run.handles, closes, "opened files must be closed exactly once on every path")
    for _, fd in ipairs(run.handles) do assert.is_true(fd._closed) end
end

local function assert_failure(run, status)
    assert_transport(run, status, "application/json")
    assert.is_nil(H.http()._headers["Content-Disposition"])
    assert.same({}, run.writes, "a failed download must not write nil, empty or partial raw bytes")
    local result = H.last_json()
    assert.is_table(result)
    assert.equal("string", type(result.error))
    assert.not_equal("", result.error)
    assert.same(result, H.json.parse(H.body()))
    return result
end

local function assert_attachment(run, filename)
    assert_transport(run, 200, "application/octet-stream")
    assert.is_nil(H.last_json())
    assert.equal('attachment; filename="' .. filename .. '"', H.http()._headers["Content-Disposition"])
    assert.same({ run.content }, run.writes)
    assert.equal(run.content, H.body())
end

after_each(function() H.finish() end)

describe("send_download integrity", function()
    it("closes and returns exact binary bytes with the existing filename/cache headers", function()
        local run = begin_download(PATH, "config podkop 'main'\r\n" .. string.char(0, 255))
        require("podkop-tweaker.http").send_download(PATH, "podkop-auto-backup.conf", "Backup file not found")
        assert_attachment(run, "podkop-auto-backup.conf")
        assert.equal(1, #run.handles)
    end)

    it("accepts a real zero-byte file, distinct from a failed read", function()
        local run = begin_download(PATH, "")
        require("podkop-tweaker.http").send_download(PATH, "empty.conf")
        assert_attachment(run, "empty.conf")
    end)

    it("returns HTTP 404 JSON for ENOENT with the caller's existing error text", function()
        local run = begin_download(PATH)
        require("podkop-tweaker.http").send_download(PATH, "backup.conf", "Backup file not found")
        assert.equal("Backup file not found", assert_failure(run, 404).error)
        assert.equal(0, #run.handles)
    end)

    for _, case in ipairs({
        { name = "permission denied", failure = { open = true, errno = 13 }, opened = 0 },
        { name = "other open IO failure", failure = { open = true, errno = 5 }, opened = 0 },
        { name = "read failure", failure = { read = true }, opened = 1 },
        { name = "close failure", failure = { close = true }, opened = 1 }
    }) do
        it("returns HTTP 500 JSON without an attachment on " .. case.name, function()
            local run = begin_download(PATH, "complete source", { [PATH] = case.failure })
            require("podkop-tweaker.http").send_download(PATH, "backup.conf")
            assert_failure(run, 500)
            assert.equal(case.opened, #run.handles)
        end)
    end

    it("discards previously read chunks when a later read fails", function()
        local run = begin_download(PATH, string.rep("x", 20000))
        run.fail_after = 1
        require("podkop-tweaker.http").send_download(PATH, "backup.conf")
        assert.equal(8192, run.bytes)
        assert.matches("late read failure", assert_failure(run, 500).details)
    end)

    it("accepts the exact bound", function()
        local run = begin_download(PATH, string.rep("x", LIMIT))
        require("podkop-tweaker.http").send_download(PATH, "backup.conf")
        assert_attachment(run, "backup.conf")
        assert.equal(LIMIT, run.bytes)
    end)

    it("rejects oversized data after at most the bound plus one byte", function()
        local run = begin_download(PATH, string.rep("x", LIMIT + 65536))
        require("podkop-tweaker.http").send_download(PATH, "backup.conf")
        assert.equal("Content exceeds size limit", assert_failure(run, 500).details)
        assert.equal(LIMIT + 1, run.bytes)
    end)
end)

describe("download endpoint delegation", function()
    for _, endpoint in ipairs({
        { "api_podkop", "export_config", "/etc/config/podkop", "podkop-config-export.conf" },
        { "api_podkop", "download_backup", PATH, "podkop-auto-backup.conf" },
        { "api_stubby", "export_config", "/etc/config/stubby", "stubby-config.txt" },
        { "api_stubby", "download_backup", "/etc/config/stubby.auto-backup", "stubby-backup.txt" },
        { "api_singbox", "export_config", "/etc/sing-box/config.json", "singbox-config.json" },
        { "api_singbox", "download_backup", "/etc/sing-box/config.json.auto-backup", "singbox-backup.json" },
        { "api_subs", "download_sub_backup", "/etc/config/podkop.sub-backup", "podkop-sub-backup.conf" }
    }) do
        it(endpoint[1] .. "." .. endpoint[2] .. " preserves the attachment name and bytes", function()
            local run = begin_download(endpoint[3], "exact saved bytes\n")
            require("podkop-tweaker." .. endpoint[1])[endpoint[2]]()
            assert_attachment(run, endpoint[4])
        end)
        it(endpoint[1] .. "." .. endpoint[2] .. " refuses an attachment after failed close", function()
            local run = begin_download(endpoint[3], "exact saved bytes\n", { [endpoint[3]] = { close = true } })
            require("podkop-tweaker." .. endpoint[1])[endpoint[2]]()
            assert_failure(run, 500)
        end)
    end
end)
