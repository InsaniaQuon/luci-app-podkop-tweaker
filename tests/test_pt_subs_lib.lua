package.path = "./usr/lib/lua/?.lua;" .. package.path

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
    it("trims log to max_lines", function()
        local tmp = os.tmpname()
        local fd = io.open(tmp, "w")
        for i = 1, 10 do
            fd:write("line " .. i .. "\n")
        end
        fd:close()

        pt.rotate_log(tmp, 3)

        fd = io.open(tmp, "r")
        local lines = {}
        for line in fd:lines() do
            table.insert(lines, line)
        end
        fd:close()
        os.remove(tmp)

        assert.equal(3, #lines)
        assert.equal("line 8", lines[1])
        assert.equal("line 9", lines[2])
        assert.equal("line 10", lines[3])
    end)

    it("does not trim short log", function()
        local tmp = os.tmpname()
        local fd = io.open(tmp, "w")
        fd:write("line 1\n")
        fd:write("line 2\n")
        fd:close()

        pt.rotate_log(tmp, 5)

        fd = io.open(tmp, "r")
        local lines = {}
        for line in fd:lines() do
            table.insert(lines, line)
        end
        fd:close()
        os.remove(tmp)

        assert.equal(2, #lines)
    end)
end)

describe("append_log", function()
    it("appends line to empty file", function()
        local tmp = os.tmpname()
        local fd = io.open(tmp, "w")
        fd:close()

        pt.append_log(tmp, 5, "first entry")

        fd = io.open(tmp, "r")
        local lines = {}
        for line in fd:lines() do
            table.insert(lines, line)
        end
        fd:close()
        os.remove(tmp)

        assert.equal(1, #lines)
        assert.equal("first entry", lines[1])
    end)

    it("rotates before appending when at max", function()
        local tmp = os.tmpname()
        local fd = io.open(tmp, "w")
        for i = 1, 3 do
            fd:write("old " .. i .. "\n")
        end
        fd:close()

        pt.append_log(tmp, 3, "new entry")

        fd = io.open(tmp, "r")
        local lines = {}
        for line in fd:lines() do
            table.insert(lines, line)
        end
        fd:close()
        os.remove(tmp)

        assert.equal(3, #lines)
        assert.equal("old 2", lines[1])
        assert.equal("old 3", lines[2])
        assert.equal("new entry", lines[3])
    end)
end)
