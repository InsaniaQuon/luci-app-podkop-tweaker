package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path
local H = require("pt_harness")
package.preload["luci.jsonc"] = function()
    return { parse = function() return nil end, stringify = function() return nil end }
end

local pt = require("pt-subs-lib")

describe("b64decode", function()
    it("decodes 'Hello'", function()
        assert.equal("Hello", pt.b64decode("SGVsbG8="))
    end)

    it("decodes 'Hello World!'", function()
        assert.equal("Hello World!", pt.b64decode("SGVsbG8gV29ybGQh"))
    end)

    it("handles empty string", function()
        assert.equal("", pt.b64decode(""))
    end)

    it("decodes single padding", function()
        assert.equal("Hi", pt.b64decode("SGk="))
    end)

    it("decodes double padding", function()
        assert.equal("A", pt.b64decode("QQ=="))
    end)

    it("decodes binary-like content", function()
        local decoded = pt.b64decode("AAEC")
        assert.equal(3, #decoded)
        assert.equal(0, string.byte(decoded, 1))
        assert.equal(1, string.byte(decoded, 2))
        assert.equal(2, string.byte(decoded, 3))
    end)

    it("strips whitespace before decoding", function()
        assert.equal("Hello", pt.b64decode("SGVs\n bG8="))
    end)
end)

describe("url_decode", function()
    it("decodes percent-encoded characters", function()
        assert.equal("My Server", pt.url_decode("My%20Server"))
    end)

    it("decodes plus as space", function()
        assert.equal("hello world", pt.url_decode("hello+world"))
    end)

    it("decodes multiple encoded chars", function()
        assert.equal("a&b=c", pt.url_decode("a%26b%3Dc"))
    end)

    it("handles empty string", function()
        assert.equal("", pt.url_decode(""))
    end)

    it("handles nil input", function()
        assert.equal("", pt.url_decode(nil))
    end)

    it("returns unchanged string without encoding", function()
        assert.equal("hello", pt.url_decode("hello"))
    end)
end)

describe("parse_proxy_link", function()
    it("parses vless with name", function()
        local p = pt.parse_proxy_link("vless://uuid@server.com:443?security=tls#My%20Server")
        assert.equal("VLESS", p.protocol)
        assert.equal("server.com", p.server)
        assert.equal("443", p.port)
        assert.equal("tls", p.security)
        assert.equal("My Server", p.name)
    end)

    it("parses vmess without fragment", function()
        local p = pt.parse_proxy_link("vmess://uuid@1.2.3.4:8080")
        assert.equal("VMESS", p.protocol)
        assert.equal("1.2.3.4", p.server)
        assert.equal("8080", p.port)
        assert.equal("1.2.3.4", p.name)
    end)

    it("parses ss link", function()
        local p = pt.parse_proxy_link("ss://method:pass@host:1234#SS%20Node")
        assert.equal("SS", p.protocol)
        assert.equal("host", p.server)
        assert.equal("1234", p.port)
        assert.equal("SS Node", p.name)
    end)

    it("parses trojan link with query params", function()
        local p = pt.parse_proxy_link("trojan://pass@trojan.example.com:443?security=tls&type=ws#TrojanNode")
        assert.equal("TROJAN", p.protocol)
        assert.equal("trojan.example.com", p.server)
        assert.equal("443", p.port)
        assert.equal("tls", p.security)
        assert.equal("TrojanNode", p.name)
    end)

    it("parses IPv6 address in brackets", function()
        local p = pt.parse_proxy_link("vless://uuid@[::1]:443#IPv6")
        assert.equal("::1", p.server)
        assert.equal("443", p.port)
        assert.equal("IPv6", p.name)
    end)

    it("returns nil for empty string", function()
        assert.is_nil(pt.parse_proxy_link(""))
    end)

    it("returns nil for nil input", function()
        assert.is_nil(pt.parse_proxy_link(nil))
    end)

    it("returns unknown for link without @", function()
        local p = pt.parse_proxy_link("vless://something")
        assert.equal("VLESS", p.protocol)
        assert.equal("unknown", p.server)
    end)

    it("handles link without port", function()
        local p = pt.parse_proxy_link("vless://uuid@noprothost#Name")
        assert.equal("noprothost", p.server)
        assert.equal("", p.port)
    end)
end)

describe("shell_escape", function()
    it("escapes normal string", function()
        assert.equal("'hello'", pt.shell_escape("hello"))
    end)

    it("escapes string with single quote", function()
        assert.equal("'it'\\''s'", pt.shell_escape("it's"))
    end)

    it("handles empty string", function()
        assert.equal("''", pt.shell_escape(""))
    end)

    it("handles number input", function()
        assert.equal("'42'", pt.shell_escape(42))
    end)
end)

describe("clean_log_field", function()
    it("keeps normal text intact", function()
        assert.equal("My Proxy Server", pt.clean_log_field("My Proxy Server"))
    end)

    it("strips newlines used for log forging", function()
        assert.equal("a b: updated", pt.clean_log_field("a\nb: updated"))
    end)

    it("strips tabs and carriage returns", function()
        assert.equal("a b c", pt.clean_log_field("a\tb\rc"))
    end)

    it("returns empty string for nil", function()
        assert.equal("", pt.clean_log_field(nil))
    end)

    it("handles empty string", function()
        assert.equal("", pt.clean_log_field(""))
    end)

    it("coerces numbers", function()
        assert.equal("42", pt.clean_log_field(42))
    end)
end)

describe("parse_subscription_raw", function()
    it("parses plain text proxy list", function()
        local raw = "vless://a@b:1#First\nvmess://c@d:2#Second\nss://e@f:3#Third"
        local proxies = pt.parse_subscription_raw(raw)
        assert.equal(3, #proxies)
        assert.equal("First", proxies[1].name)
        assert.equal("Second", proxies[2].name)
        assert.equal("Third", proxies[3].name)
    end)

    it("parses base64-encoded list", function()
        local raw = "dmxlc3M6Ly9hQGI6MSNLaXR0ZW4Kdmxlc3M6Ly9jQGQ6MiNDYXQK"
        local proxies = pt.parse_subscription_raw(raw)
        assert.equal(2, #proxies)
        assert.equal("Kitten", proxies[1].name)
        assert.equal("Cat", proxies[2].name)
    end)

    it("skips non-proxy lines", function()
        local raw = "some header\nvless://a@b:1#Node\n\nanother line"
        local proxies = pt.parse_subscription_raw(raw)
        assert.equal(1, #proxies)
        assert.equal("Node", proxies[1].name)
    end)

    it("returns empty table for garbage input", function()
        local proxies = pt.parse_subscription_raw("random text without links")
        assert.equal(0, #proxies)
    end)

    it("handles Windows line endings", function()
        local raw = "vless://a@b:1#First\r\nvmess://c@d:2#Second"
        local proxies = pt.parse_subscription_raw(raw)
        assert.equal(2, #proxies)
    end)
end)

describe("strict subscription state IO", function()
    local path = "/virtual/subs.json"
    after_each(function() H.finish() end)

    it("initializes only a missing first-use file without writing it", function()
        H.begin({})
        local s = require("pt-subs-lib")
        local data, err = s.read_subs(path)
        assert.same({}, data)
        assert.is_nil(err)
        assert.falsy(H.vfs_exists(path))
        assert.same({}, H.stage_paths())
        assert.is_true(s.write_subs(data, path))
        assert.equal(1, s.read_subs(path).version)
        assert.is_nil(data.version, "serialization must not modify the caller's metadata")
    end)

    for _, raw in ipairs({ "", " \r\n\t", "{broken", "[]", "[{}]", "true", "42", "null", '"text"',
        '{"settings":false}', '{"settings":{"auto_update_interval":"4"}}',
        '{"settings":{"auto_update_on_restart":"1"}}', '{"settings":{"log_display_count":0}}',
        '{"main":[7]}', '{"main":[{"subscription_url":false}]}', '{"main":[{"proxy_name":[]}]}',
        '{"main":[{"last_updated":5}]}', '{"version":"1"}' }) do
        it("rejects existing invalid/typed state and retains its exact bytes: " .. raw:sub(1, 60), function()
            H.begin({})
            H.vfs_write(path, raw)
            local data, err = require("pt-subs-lib").read_subs(path)
            assert.is_nil(data)
            assert.is_string(err)
            assert.equal(raw, H.vfs_read(path))
            assert.same({}, H.stage_paths())
        end)
    end

    for _, operation in ipairs({ "open", "read", "close" }) do
        it("does not treat an existing " .. operation .. " failure as first use", function()
            H.begin({ failures = { [path] = { [operation] = true, errno = 5 } } })
            local raw = '{"version":3,"main":[{"subscription_url":"https://provider.test"}]}'
            H.vfs_write(path, raw)
            local data, err = require("pt-subs-lib").read_subs(path)
            assert.is_nil(data)
            assert.matches("Cannot read subscriptions", err)
            assert.equal(raw, H.vfs_read(path))
        end)
    end

    it("rejects non-ENOENT open failure even when no file can be inspected", function()
        H.begin({ failures = { [path] = { open = true, errno = 13 } } })
        local data, err = require("pt-subs-lib").read_subs(path)
        assert.is_nil(data)
        assert.is_string(err)
        assert.falsy(H.vfs_exists(path))
    end)

    it("bounds the complete read instead of accepting an oversized state", function()
        H.begin({})
        local s = require("pt-subs-lib")
        local raw = '{"future":"' .. string.rep("x", s.SUB_MAX_SIZE) .. '"}'
        H.vfs_write(path, raw)
        local data, err = s.read_subs(path)
        assert.is_nil(data)
        assert.matches("size limit", err)
        assert.equal(raw, H.vfs_read(path))
    end)

    it("round-trips version, sparse slots and unknown fields without mutating the input", function()
        H.begin({})
        local s = require("pt-subs-lib")
        H.vfs_write(path, '{"version":7,"future":{"flag":"keep"},"future_flag":"preserve","settings":{"future":{"a":1}},' ..
            '"main":[null,false,{"subscription_url":"https://provider.test","proxy_name":"third","future":{"b":2}}]}')
        local data = assert(s.read_subs(path))
        assert.is_nil(data.main[1])
        assert.is_false(data.main[2])
        assert.equal("third", data.main[3].proxy_name)
        assert.is_true(s.write_subs(data, path))
        local written = assert(s.read_subs(path))
        assert.equal(7, written.version)
        assert.same({ flag = "keep" }, written.future)
        assert.equal("preserve", written.future_flag)
        assert.same({ a = 1 }, written.settings.future)
        assert.same({ b = 2 }, written.main[3].future)
        assert.is_false(written.main[1])
        assert.is_nil(data.main[1], "filling positional holes must not mutate a read snapshot")
        assert.equal(7, data.version)
    end)

    for _, operation in ipairs({ "open", "write", "close", "rename" }) do
        it("retains the live state and metadata on publication " .. operation .. " failure", function()
            H.begin({ failures = { [operation == "rename" and path or path .. ".tmp.*"] = { [operation] = true, partial = 3 } } })
            local s = require("pt-subs-lib")
            local before = '{"version":7,"future":{"flag":"old"}}'
            H.vfs_write(path, before)
            local data = { version = 7, future = { flag = "new" } }
            local ok, err = s.write_subs(data, path)
            assert.is_false(ok)
            assert.is_string(err)
            assert.equal(before, H.vfs_read(path))
            assert.same({ version = 7, future = { flag = "new" } }, data)
            for _, stage in ipairs(H.stage_paths(path .. ".tmp.*")) do assert.falsy(H.vfs_exists(stage)) end
        end)
    end

    it("timestamp mutation keeps unknown association fields and checks the final write", function()
        H.begin({})
        local s = require("pt-subs-lib")
        H.vfs_write(path, '{"version":4,"main":[{"subscription_url":"https://provider.test","future":"keep"}]}')
        assert.is_true(s.update_subs_timestamp(path, "main", 0, "auto"))
        local data = assert(s.read_subs(path))
        assert.equal(4, data.version)
        assert.equal("keep", data.main[1].future)
        local before = H.vfs_read(path)
        H.state().failures[path] = { rename = true }
        local ok, err = s.update_subs_timestamp(path, "main", 0, "manual")
        assert.is_false(ok)
        assert.is_string(err)
        assert.equal(before, H.vfs_read(path))
    end)
end)

describe("subscription publication versus lock-release uncertainty", function()
    local path, lock = "/virtual/subs.json", "/var/lock/podkop-tweaker-subscriptions.lock"
    after_each(function() H.finish() end)

    for _, published in ipairs({ false, true }) do
        it("reports only actual state publication when release fails (published=" .. tostring(published) .. ")", function()
            local failures = { [lock] = { rmdir = true } }
            if not published then failures[path .. ".tmp.*"] = { write = true, partial = 3 } end
            H.begin({ strict = true, failures = failures })
            local s = require("pt-subs-lib")
            local before = '{"version":7,"settings":{"log_display_count":4}}'
            H.vfs_write(path, before)
            local ok, err, applied, unknown = s.write_subs({ version = 7, settings = { log_display_count = 12 } }, path)
            assert.is_false(ok)
            assert.equal(published, applied == true)
            assert.is_true(unknown)
            assert.matches("cannot release owned lock", err)
            if published then
                assert.equal(12, s.read_subs(path).settings.log_display_count)
            else
                assert.matches("Injected write failure", err)
                assert.equal(before, H.vfs_read(path))
            end
        end)
    end

    it("retains the timestamp read failure without claiming applied state when release also fails", function()
        H.begin({ strict = true, failures = { [lock] = { rmdir = true }, [path] = { read = true } } })
        local before = '{"main":[{"subscription_url":"https://provider.test","proxy_name":"node"}]}'
        H.vfs_write(path, before)
        local ok, err, applied, unknown = require("pt-subs-lib").update_subs_timestamp(path, "main", 0, "auto")
        assert.is_false(ok)
        assert.falsy(applied)
        assert.is_true(unknown)
        assert.matches("Cannot read subscriptions", err)
        assert.matches("cannot release owned lock", err)
        assert.equal(before, H.vfs_read(path))
        assert.same({}, H.stage_paths())
    end)

    for _, operation in ipairs({ "read failure", "rotation no-op", "append publication" }) do
        it("keeps log publication separate from release failure after " .. operation, function()
            local log = "/virtual/log"
            local failures = { [lock] = { rmdir = true } }
            if operation == "read failure" then failures[log] = { read = true } end
            H.begin({ strict = true, failures = failures })
            local before = "old event|auto|updated=0|unchanged=1|failed=0\n"
            H.vfs_write(log, before)
            local s = require("pt-subs-lib")
            local ok, err, applied, unknown
            if operation == "rotation no-op" then ok, err, applied, unknown = s.rotate_log(log, 5)
            else ok, err, applied, unknown = s.append_log(log, 5, "new event|auto|updated=0|unchanged=0|failed=0") end
            assert.is_false(ok)
            assert.is_true(unknown)
            assert.matches("cannot release owned lock", err)
            assert.equal(operation == "append publication", applied == true)
            if operation ~= "append publication" then
                assert.equal(before, H.vfs_read(log))
                assert.same({}, H.stage_paths())
            end
            if operation == "read failure" then assert.matches("Cannot read subscription log", err) end
        end)
    end
end)

describe("rotate_log", function()
    before_each(function() H.begin({}) end)
    after_each(function() H.finish() end)
    it("trims log to max events", function()
        local tmp = "/virtual/log"
        local fd = io.open(tmp, "w")
        for i = 1, 5 do
            fd:write("event " .. i .. "|manual|updated=0|unchanged=0|failed=0\n")
            fd:write("  section:\n    slot 1 server: updated\n")
        end
        fd:close()

        pt.rotate_log(tmp, 3)

        fd = io.open(tmp, "r")
        local lines = {}
        for line in fd:lines() do lines[#lines + 1] = line end
        fd:close()
        os.remove(tmp)

        local events = 0
        for _, l in ipairs(lines) do
            if not l:match("^%s") then events = events + 1 end
        end
        assert.equal(3, events)
        assert.equal("event 3|manual|updated=0|unchanged=0|failed=0", lines[1])
    end)

    it("does not trim short log", function()
        local tmp = "/virtual/log"
        local fd = io.open(tmp, "w")
        fd:write("event 1|auto|updated=1|unchanged=0|failed=0\n")
        fd:close()

        pt.rotate_log(tmp, 5)

        fd = io.open(tmp, "r")
        local lines = {}
        for line in fd:lines() do lines[#lines + 1] = line end
        fd:close()
        os.remove(tmp)

        assert.equal(1, #lines)
    end)
end)

describe("append_log", function()
    before_each(function() H.begin({}) end)
    after_each(function() H.finish() end)
    it("appends text to empty file", function()
        local tmp = "/virtual/log"
        local fd = io.open(tmp, "w")
        fd:close()

        pt.append_log(tmp, 5, "12:00 30.05.2026|manual|updated=1|unchanged=0|failed=0")

        fd = io.open(tmp, "r")
        local lines = {}
        for line in fd:lines() do lines[#lines + 1] = line end
        fd:close()
        os.remove(tmp)

        assert.equal(1, #lines)
        assert.equal("12:00 30.05.2026|manual|updated=1|unchanged=0|failed=0", lines[1])
    end)

    it("appends multiline text with details", function()
        local tmp = "/virtual/log"
        local fd = io.open(tmp, "w")
        fd:close()

        local text = "12:00 30.05.2026|manual|updated=1|unchanged=0|failed=0\n  proxy_group:\n    server: updated"
        pt.append_log(tmp, 5, text)

        fd = io.open(tmp, "r")
        local lines = {}
        for line in fd:lines() do lines[#lines + 1] = line end
        fd:close()
        os.remove(tmp)

        assert.equal(3, #lines)
        assert.equal("12:00 30.05.2026|manual|updated=1|unchanged=0|failed=0", lines[1])
        assert.equal("  proxy_group:", lines[2])
        assert.equal("    server: updated", lines[3])
    end)

    it("rotates when exceeding max_events", function()
        local tmp = "/virtual/log"
        local fd = io.open(tmp, "w")
        fd:close()

        for i = 1, 4 do
            pt.append_log(tmp, 3, "event " .. i .. "|auto|updated=0|unchanged=0|failed=0")
        end

        fd = io.open(tmp, "r")
        local lines = {}
        for line in fd:lines() do lines[#lines + 1] = line end
        fd:close()
        os.remove(tmp)

        assert.equal(3, #lines)
        assert.equal("event 2|auto|updated=0|unchanged=0|failed=0", lines[1])
    end)

    for _, operation in ipairs({ "open", "read", "close", "write", "rename" }) do
        it("reports log " .. operation .. " failure without losing the existing events", function()
            local path = "/virtual/log"
            local failure_path = (operation == "write" and path .. ".tmp-write.*") or path
            H.state().failures[failure_path] = { [operation] = true, partial = 2 }
            local before = "event 1|auto|updated=1|unchanged=0|failed=0\n  main:\n    node: updated\n"
            H.vfs_write(path, before)
            local ok, err = require("pt-subs-lib").append_log(path, 1, "event 2|auto|updated=0|unchanged=1|failed=0")
            assert.is_false(ok)
            assert.is_string(err)
            assert.equal(before, H.vfs_read(path))
        end)
    end
end)

describe("_is_valid_update_path", function()
    it("rejects path traversal", function()
        assert.is_false(pt._is_valid_update_path("../../etc/passwd", false))
        assert.is_false(pt._is_valid_update_path("../../etc/passwd", true))
    end)

    it("accepts lua files in strict mode", function()
        assert.is_true(pt._is_valid_update_path("usr/lib/lua/luci/controller/podkop-tweaker.lua", false))
        assert.is_true(pt._is_valid_update_path("usr/lib/lua/pt-subs-lib.lua", false))
    end)

    it("accepts htm templates in strict mode", function()
        assert.is_true(pt._is_valid_update_path("usr/lib/lua/luci/view/podkop-tweaker/config.htm", false))
    end)

    it("accepts shared js/css assets in strict mode", function()
        assert.is_true(pt._is_valid_update_path("www/luci-static/resources/podkop-tweaker/common.js", false))
        assert.is_true(pt._is_valid_update_path("www/luci-static/resources/podkop-tweaker/common.css", false))
        assert.is_false(pt._is_valid_update_path("www/luci-static/resources/podkop-tweaker/common.html", false))
        assert.is_false(pt._is_valid_update_path("www/luci-static/resources/other/app.js", false))
        assert.is_false(pt._is_valid_update_path("www/luci-static/resources/podkop-tweaker/sub/dir/x.js", false))
    end)

    it("accepts json menu and acl in strict mode", function()
        assert.is_true(pt._is_valid_update_path("usr/share/luci/menu.d/luci-app-podkop-tweaker.json", false))
        assert.is_true(pt._is_valid_update_path("usr/share/rpcd/acl.d/luci-app-podkop-tweaker.json", false))
    end)

    it("rejects unknown paths in strict mode", function()
        assert.is_false(pt._is_valid_update_path("usr/lib/lua/some/dir/file.txt", false))
        assert.is_false(pt._is_valid_update_path("etc/config/podkop", false))
    end)

    it("accepts any non-traversal path in relaxed mode", function()
        assert.is_true(pt._is_valid_update_path("usr/lib/lua/some/new/file.lua", true))
        assert.is_true(pt._is_valid_update_path("usr/share/luci/menu.d/something.json", true))
        assert.is_true(pt._is_valid_update_path("etc/config/podkop", true))
        assert.is_true(pt._is_valid_update_path("etc/init.d/podkop-fragment", true))
        assert.is_true(pt._is_valid_update_path("usr/bin/podkop-fragment-patch.sh", true))
        assert.is_true(pt._is_valid_update_path("tmp/evil.sh", true))
    end)

    it("still rejects traversal in relaxed mode", function()
        assert.is_false(pt._is_valid_update_path("../etc/passwd", true))
        assert.is_false(pt._is_valid_update_path("foo/../../bar", true))
    end)

    it("accepts fragment module paths in strict mode", function()
        assert.is_true(pt._is_valid_update_path("usr/bin/podkop-fragment-patch.sh", false))
        assert.is_true(pt._is_valid_update_path("etc/init.d/podkop-fragment", false))
        assert.is_true(pt._is_valid_update_path("etc/config/podkop-fragment", false))
    end)

    it("rejects similar but different etc paths in strict mode", function()
        assert.is_false(pt._is_valid_update_path("etc/init.d/podkop", false))
        assert.is_false(pt._is_valid_update_path("etc/config/podkop", false))
        assert.is_false(pt._is_valid_update_path("etc/init.d/sing-box", false))
    end)
end)

describe("backup_file", function()
    local test_dir = "/virtual/backups"

    before_each(function()
        H.begin({})
    end)

    after_each(function()
        H.finish()
    end)

    it("returns false when source does not exist", function()
        assert.is_false(pt.backup_file(test_dir .. "/nonexistent", test_dir .. "/backup"))
    end)

    it("creates backup from source to destination", function()
        local src = test_dir .. "/source.conf"
        local dst = test_dir .. "/backup.conf"
        local fd = io.open(src, "w")
        fd:write("config stubby 'global'\n\toption manual '0'\n")
        fd:close()

        assert.is_true(pt.backup_file(src, dst))

        local bfd = io.open(dst, "r")
        assert.is_not_nil(bfd)
        local content = bfd:read("*a")
        bfd:close()
        assert.equal("config stubby 'global'\n\toption manual '0'\n", content)
    end)

    it("overwrites existing backup", function()
        local src = test_dir .. "/source.conf"
        local dst = test_dir .. "/backup.conf"

        local fd = io.open(dst, "w")
        fd:write("old content")
        fd:close()

        fd = io.open(src, "w")
        fd:write("new content")
        fd:close()

        pt.backup_file(src, dst)

        local bfd = io.open(dst, "r")
        assert.is_not_nil(bfd)
        local content = bfd:read("*a")
        bfd:close()
        assert.equal("new content", content)
    end)

    it("does not leave owned unique stages on success", function()
        local src = test_dir .. "/source.conf"
        local dst = test_dir .. "/backup.conf"

        local fd = io.open(src, "w")
        fd:write("data")
        fd:close()

        pt.backup_file(src, dst)

        local stages = H.stage_paths(dst .. ".tmp.*")
        assert.equal(1, #stages)
        for _, stage in ipairs(stages) do assert.falsy(H.vfs_exists(stage)) end
    end)

    it("returns false when destination dir is not writable", function()
        H.state().failures["/nonexistent_dir/backup.conf.tmp.*"] = { open = true }
        local src = test_dir .. "/source.conf"
        local fd = io.open(src, "w")
        fd:write("data")
        fd:close()

        assert.is_false(pt.backup_file(src, "/nonexistent_dir/backup.conf"))
    end)
end)
