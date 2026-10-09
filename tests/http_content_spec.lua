-- Real controller adapters: streamed config/bundle bytes, limits and pre-mutation CSRF.
package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path
local H = require("pt_harness")
local CTRL = "luci.controller.podkop-tweaker"
local TOKEN = string.rep("c", 64)
local ROUTES = {
    { "api_save_config", "api_podkop", "save_config", 1048576 },
    { "api_import_config", "api_podkop", "import_config", 1048576 },
    { "api_save_stubby_config", "api_stubby", "save_config", 1048576 },
    { "api_import_stubby_config", "api_stubby", "import_config", 1048576 },
    { "api_save_singbox_config", "api_singbox", "save_config", 2097152 },
    { "api_import_singbox_config", "api_singbox", "import_config", 2097152 },
    { "api_import_bundle", "api_bundle", "import", 4194304 }
}
local function begin(route, options)
    options = options or {}
    local payload = options.payload or "content"
    H.begin({ env = { CONTENT_TYPE = options.legacy and "application/x-www-form-urlencoded" or "multipart/form-data; boundary=test" },
        fv = { token = options.bad_token and "wrong" or TOKEN, content = options.legacy and payload or "must not override file bytes", items = "podkop,subs" } })
    H.vfs_write("/etc/podkop-tweaker.token", TOKEN)
    local http = H.http()
    local callback, parsed, received
    local formvalue = http.formvalue
    http.setfilehandler = function(fn) assert.falsy(parsed); callback = fn end
    http.formvalue = function(key)
        if not parsed then
            parsed = true
            if options.parse_error then error("POST data exceeds maximum allowed length") end
            if not options.legacy then
                assert.is_function(callback, "collector must precede form/CSRF parsing")
                local parts = options.parts or { { chunks = { payload:sub(1, 8192), payload:sub(8193) } } }
                for _, part in ipairs(parts) do
                    local meta = { name = part.name or "content_file", file = part.filename == false and "" or part.filename or "config.txt" }
                    for _, chunk in ipairs(part.chunks or {}) do callback(meta, chunk, false) end
                    if not part.incomplete then callback(meta, "", true) end
                end
            end
        end
        return formvalue(key)
    end
    local module = require("podkop-tweaker." .. route[2])
    module[route[3]] = function(content, file, items)
        if options.handler_error then error("private handler exception") end
        received = { content = content, file = file, items = items }
        return { success = true }
    end
    package.loaded[CTRL] = nil
    local ctl = require(CTRL)
    return function() ctl[route[1]](); return received end
end
after_each(function() H.finish(); package.loaded[CTRL] = nil end)

describe("bounded config/bundle HTTP content", function()
    for _, route in ipairs(ROUTES) do
        it(route[1] .. " accepts raw UTF-8 above the text-field limit", function()
            local payload = "config section 'main'\n" .. string.rep("# domain.example — тест\n", 7000)
            assert.is_true(#payload > 102400)
            local run = begin(route, { payload = payload })
            local received = run()
            assert.equal(payload, received.content)
            assert.is_true(H.last_json().success)
            if route[3] == "import" then assert.equal("podkop,subs", received.items) end
        end)
        it(route[1] .. " rejects oversized streamed content before handler invocation", function()
            local run = begin(route, { payload = string.rep("x", route[4] + 1) })
            assert.is_nil(run())
            assert.matches("too large", H.last_json().error)
            assert.equal(400, H.http()._status[1].code)
        end)
        it(route[1] .. " preserves legacy text POSTs", function()
            assert.equal("old text", begin(route, { legacy = true, payload = "old text" })().content)
        end)
        it(route[1] .. " accepts its exact documented file-byte limit", function()
            local payload = string.rep("x", route[4])
            assert.equal(payload, begin(route, { payload = payload })().content)
            assert.is_true(H.last_json().success)
        end)
        it(route[1] .. " rejects invalid CSRF before invoking its handler", function()
            assert.is_nil(begin(route, { bad_token = true })())
            assert.equal(403, H.http()._status[1].code)
        end)
    end

    it("invalid CSRF prevents handlers and all config/backup writes", function()
        local run = begin(ROUTES[1], { bad_token = true })
        assert.is_nil(run())
        assert.equal(403, H.http()._status[1].code)
        for _, operation in ipairs(H.state().io_log) do assert.falsy(operation.operation == "write") end
    end)
    for _, parts in ipairs({ {}, { { chunks = { "partial" }, incomplete = true } },
        { { chunks = { "first" } }, { chunks = { "second" } } }, { { name = "unexpected", chunks = { "payload" } } } }) do
        it("rejects missing, incomplete, repeated or foreign file parts", function()
            assert.is_nil(begin(ROUTES[1], { parts = parts })())
            assert.truthy(H.last_json().error)
            assert.equal(400, H.http()._status[1].code)
        end)
    end
    it("turns form-parser failures into complete JSON diagnostics", function()
        assert.is_nil(begin(ROUTES[1], { parse_error = true, legacy = true })())
        assert.equal(400, H.http()._status[1].code)
        assert.matches("maximum allowed length", H.last_json().details)
    end)
    it("rejects a file with no filename and preserves generic handler-exception responses", function()
        assert.is_nil(begin(ROUTES[1], { parts = { { filename = false, chunks = { "data" } } } })())
        assert.matches("Missing content file filename", H.last_json().error)
        H.finish()
        package.loaded[CTRL] = nil
        assert.is_nil(begin(ROUTES[1], { handler_error = true })())
        assert.same({ error = "Internal error" }, H.last_json())
        assert.equal(0, #H.http()._status, "handler failures are not classified as form-parser failures")
    end)
end)
