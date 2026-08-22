package.path = "./usr/lib/lua/?.lua;" .. package.path

local D = require("podkop-tweaker.diag")

describe("parse_lookup_ip", function()
    it("parses busybox multi-address output (server echo + v4 + v6)", function()
        local raw = "Server:\t1.1.1.1\n" ..
            "Address:\t1.1.1.1#53\n" ..
            "\n" ..
            "Name:\tgoogle.com\n" ..
            "Address 1: 173.194.222.100\n" ..
            "Address 2: 2a00:1450:4009:81::200e\n"
        assert.equal("173.194.222.100", D.parse_lookup_ip(raw))
    end)

    it("parses old-style repeated Address lines", function()
        local raw = "Server:\t127.0.0.1\n" ..
            "Address:\t127.0.0.1:53\n" ..
            "Name:\tgoogle.com\n" ..
            "Address:\t173.0.0.100\n" ..
            "Address:\t2a00::1\n"
        assert.equal("173.0.0.100", D.parse_lookup_ip(raw))
    end)

    it("prefers the resolved v4 over the server echo", function()
        local raw = "Server:\t127.0.0.1\n" ..
            "Address:\t127.0.0.1:53\n" ..
            "Name:\tx.org\n" ..
            "Address:\t93.184.216.34\n"
        assert.equal("93.184.216.34", D.parse_lookup_ip(raw))
    end)

    it("falls back to ipv6 when no v4 answer", function()
        local raw = "Server:\t1.1.1.1\n" ..
            "Address:\t1.1.1.1#53\n" ..
            "Name:\tgoogle.com\n" ..
            "Address 1: 2a00:1450:4009:81::200e\n"
        assert.equal("2a00:1450:4009:81::200e", D.parse_lookup_ip(raw))
    end)

    it("returns empty string when nothing matched", function()
        assert.equal("", D.parse_lookup_ip(";; connection timed out; no servers could be reached\n"))
    end)

    it("does not truncate a quad at a colon-port", function()
        local raw = "Address:\t93.184.216.34:53\n"
        assert.equal("93.184.216.34", D.parse_lookup_ip(raw))
    end)
end)
