package.path = "./usr/lib/lua/?.lua;" .. package.path
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

describe("rotate_log", function()
    it("trims log to max events", function()
        local tmp = os.tmpname()
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
        local tmp = os.tmpname()
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
    it("appends text to empty file", function()
        local tmp = os.tmpname()
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
        local tmp = os.tmpname()
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
        local tmp = os.tmpname()
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
    local test_dir = "/tmp/pt-test-backup-" .. tostring(os.time())

    before_each(function()
        os.execute("mkdir -p " .. test_dir .. " 2>/dev/null")
    end)

    after_each(function()
        os.execute("rm -rf " .. test_dir .. " 2>/dev/null")
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

    it("does not leave .tmp file on success", function()
        local src = test_dir .. "/source.conf"
        local dst = test_dir .. "/backup.conf"

        local fd = io.open(src, "w")
        fd:write("data")
        fd:close()

        pt.backup_file(src, dst)

        local tmpfd = io.open(dst .. ".tmp", "r")
        assert.is_nil(tmpfd)
    end)

    it("returns false when destination dir is not writable", function()
        local src = test_dir .. "/source.conf"
        local fd = io.open(src, "w")
        fd:write("data")
        fd:close()

        assert.is_false(pt.backup_file(src, "/nonexistent_dir/backup.conf"))
    end)
end)
