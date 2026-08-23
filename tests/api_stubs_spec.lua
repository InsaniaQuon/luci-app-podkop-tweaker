-- api_stubs_spec | v1.0.0 | 23.08.2026 | Self-tests for pt_harness (VFS overlay, fakes, isolation)

package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path

local H = require("pt_harness")
local json = require("pt_json")

after_each(function()
    H.finish()
end)

-- === pt_json ===

describe("pt_json encode", function()
    it("encodes scalars", function()
        assert.equal("5", json.stringify(5))
        assert.equal("-3", json.stringify(-3))
        assert.equal("1.5", json.stringify(1.5))
        assert.equal("true", json.stringify(true))
        assert.equal("false", json.stringify(false))
        assert.equal('"hi"', json.stringify("hi"))
    end)

    it("escapes strings", function()
        assert.equal('"a\\nb\\"c\\\\d"', json.stringify('a\nb"c\\d'))
        assert.equal('"\\t"', json.stringify("\t"))
        assert.equal('"\\u0001"', json.stringify("\1"))
    end)

    it("encodes arrays and objects", function()
        assert.equal("[1,2,3]", json.stringify({ 1, 2, 3 }))
        assert.equal('{"a":1}', json.stringify({ a = 1 }))
        assert.equal("[true,false]", json.stringify({ true, false }))
        local holed = {}
        holed[1] = "a"
        holed[3] = "c"
        assert.equal('["a",null,"c"]', json.stringify(holed))
    end)

    it("encodes empty table as object", function()
        assert.equal("{}", json.stringify({}))
    end)

    it("encodes nested structures deterministically", function()
        local out = json.stringify({ b = 2, a = { x = "y" } })
        assert.equal('{"a":{"x":"y"},"b":2}', out)
    end)
end)

describe("pt_json parse", function()
    it("parses scalars", function()
        assert.equal(42, json.parse("42"))
        assert.equal(-1.25, json.parse("-1.25"))
        assert.equal(true, json.parse("true"))
        assert.equal(false, json.parse("false"))
        assert.is_nil(json.parse("null"))
    end)

    it("parses containers", function()
        local t = json.parse('{"a": [1, {"b": "c"}], "d": false}')
        assert.same({ a = { 1, { b = "c" } }, d = false }, t)
    end)

    it("handles whitespace and trailing garbage", function()
        assert.same({ 1, 2 }, json.parse("  [1, 2]  "))
        assert.is_nil(json.parse("[1] x"))
    end)

    it("decodes escape sequences", function()
        assert.equal('a"b\\c\nd\te', json.parse('"a\\"b\\\\c\\nd\\te"'))
        assert.equal("\195\169", json.parse('"\\u00e9"'))
        assert.equal("\240\159\152\128", json.parse('"\\uD83D\\uDE00"'))
    end)

    it("returns nil for invalid input", function()
        assert.is_nil(json.parse(""))
        assert.is_nil(json.parse("{"))
        assert.is_nil(json.parse("[1,]"))
        assert.is_nil(json.parse('{"a":}'))
        assert.is_nil(json.parse("nul"))
        assert.is_nil(json.parse('{"a" 1}'))
    end)

    it("roundtrips", function()
        local src = { s = 'q"\\\n', n = 7, arr = { "x", "y" }, flag = true }
        assert.same(src, json.parse(json.stringify(src)))
    end)
end)

-- === VFS overlay ===

describe("vfs overlay", function()
    it("writes and reads files", function()
        H.begin()
        local fd = assert(io.open("/etc/config/test.conf", "w"))
        fd:write("line1\nline2\n")
        fd:close()
        local rf = assert(io.open("/etc/config/test.conf", "r"))
        assert.equal("line1\nline2\n", rf:read("*a"))
        rf:close()
        assert.equal("line1\nline2\n", H.vfs_read("/etc/config/test.conf"))
    end)

    it("read *l iterates lines", function()
        H.begin()
        H.vfs_write("/tmp/lines.txt", "a\nb\nc")
        local fd = assert(io.open("/tmp/lines.txt", "r"))
        assert.equal("a", fd:read("*l"))
        assert.equal("b", fd:read("*l"))
        assert.equal("c", fd:read("*l"))
        assert.is_nil(fd:read("*l"))
        fd:close()
    end)

    it("lines() iterator works", function()
        H.begin()
        H.vfs_write("/tmp/l2.txt", "x\ny\n")
        local fd = assert(io.open("/tmp/l2.txt", "r"))
        local acc = {}
        for line in fd:lines() do acc[#acc + 1] = line end
        fd:close()
        assert.same({ "x", "y" }, acc)
    end)

    it("seek end reports size", function()
        H.begin()
        H.vfs_write("/tmp/sz.bin", "12345")
        local fd = assert(io.open("/tmp/sz.bin", "r"))
        assert.equal(5, fd:seek("end"))
        fd:close()
    end)

    it("missing file reads as nil", function()
        H.begin()
        assert.is_nil(io.open("/etc/nope.conf", "r"))
    end)

    it("rename moves entries", function()
        H.begin()
        H.vfs_write("/tmp/a.tmp", "payload")
        assert.truthy(os.rename("/tmp/a.tmp", "/tmp/a.final"))
        assert.is_nil(H.vfs_read("/tmp/a.tmp"))
        assert.equal("payload", H.vfs_read("/tmp/a.final"))
    end)

    it("remove deletes existing and fails missing", function()
        H.begin()
        H.vfs_write("/tmp/del.txt", "x")
        assert.truthy(os.remove("/tmp/del.txt"))
        assert.falsy(H.vfs_exists("/tmp/del.txt"))
        local ok = os.remove("/tmp/absent.txt")
        assert.falsy(ok)
    end)

    it("append mode starts at end", function()
        H.begin()
        H.vfs_write("/tmp/app.log", "one\n")
        local fd = assert(io.open("/tmp/app.log", "a"))
        fd:write("two\n")
        fd:close()
        assert.equal("one\ntwo\n", H.vfs_read("/tmp/app.log"))
    end)
end)

-- === popen / sys.exec ===

describe("command fakes", function()
    it("io.popen returns scripted output and logs", function()
        H.begin({
            popen = function(cmd)
                if cmd:find("curl", 1, true) then return "200 0.5\n" end
                return ""
            end
        })
        local fd = io.popen("curl -s https://x 2>&1")
        assert.equal("200 0.5\n", fd:read("*a"))
        fd:close()
        assert.equal(1, #H.popen_cmds())
        assert.equal("curl -s https://x 2>&1", H.popen_cmds()[1])
    end)

    it("sys.exec matches by substring and function", function()
        H.begin({
            sys = {
                { match = "pidof", out = "4321\n" },
                { match = function(cmd) return cmd:find("^ls ") ~= nil end, out = "/etc/rc.d/S99x\n" }
            }
        })
        local sys = H.reload("luci.sys")
        assert.equal("4321\n", sys.exec("pidof sing-box 2>/dev/null"))
        assert.equal("/etc/rc.d/S99x\n", sys.exec("ls /etc/rc.d/S*stubby 2>/dev/null"))
        assert.equal("", sys.exec("unknown-cmd"))
        assert.equal(3, #H.exec_cmds())
    end)

    it("os.execute records and succeeds", function()
        H.begin()
        local ok = os.execute("mkdir -p /tmp/whatever 2>/dev/null")
        assert.truthy(ok)
        assert.equal("mkdir -p /tmp/whatever 2>/dev/null", H.execute_cmds()[1])
    end)
end)

-- === uci fake ===

describe("uci fake", function()
    it("seeds sections and answers get", function()
        H.begin({
            uci = {
                stubby = {
                    H.sec("global", "stubby", { listen_address = "127.0.0.53@53" }),
                    H.sec("r1", "resolver", { address = "1.1.1.1", tls_port = "853" })
                }
            }
        })
        local uci = H.reload("luci.model.uci").cursor()
        local u = uci:get("stubby", "global", "listen_address")
        assert.equal("127.0.0.53@53", u)
        assert.equal("853", uci:get("stubby", "r1", "tls_port"))
        assert.is_nil(uci:get("stubby", "absent", "x"))
    end)

    it("get returns tables for lists", function()
        H.begin({
            uci = {
                podkop = {
                    H.sec("main", "section", {
                        connection_type = "proxy",
                        proxy_config_type = "urltest",
                        urltest_proxy_links = { "vless://a", "vless://b" }
                    })
                }
            }
        })
        local uci = H.reload("luci.model.uci").cursor()
        local l = uci:get("podkop", "main", "urltest_proxy_links")
        assert.same({ "vless://a", "vless://b" }, l)
    end)

    it("foreach filters by type and exposes .name", function()
        H.begin({
            uci = {
                stubby = {
                    H.sec("global", "stubby", {}),
                    H.sec("r1", "resolver", { address = "1.1.1.1" }),
                    H.sec("r2", "resolver", { address = "9.9.9.9" })
                }
            }
        })
        local uci = H.reload("luci.model.uci").cursor()
        local seen = {}
        uci:foreach("stubby", "resolver", function(s)
            seen[#seen + 1] = s[".name"] .. "=" .. (s.address or "")
        end)
        assert.same({ "r1=1.1.1.1", "r2=9.9.9.9" }, seen)
        local cnt = 0
        uci:foreach("missing", "resolver", function() cnt = cnt + 1 end)
        assert.equal(0, cnt)
    end)

    it("set declares sections and sets options; commit logs", function()
        H.begin()
        local uci = H.reload("luci.model.uci").cursor()
        uci:set("argon", "typography", "typography")
        uci:set("argon", "typography", "font_size", "16")
        uci:commit("argon")
        assert.equal("typography", uci:get("argon", "typography"))
        assert.equal("16", uci:get("argon", "typography", "font_size"))
        assert.same({ "argon" }, H.commits())
    end)
end)

-- === http fake ===

describe("http fake", function()
    it("captures formvalues, env, json, headers, status", function()
        H.begin({
            fv = { token = "abc", content = "config text" },
            env = { SERVER_NAME = "192.168.8.1:80" }
        })
        local http = H.http()
        assert.equal("abc", http.formvalue("token"))
        assert.equal("config text", http.formvalue("content"))
        assert.is_nil(http.formvalue("nope"))
        assert.equal("192.168.8.1:80", http.getenv("SERVER_NAME"))
        http.prepare_content("application/json")
        http.header("Cache-Control", "no-cache")
        http.status(403, "Forbidden")
        http.write_json({ error = "denied" })
        http.write("tail")
        assert.same({ error = "denied" }, H.last_json())
        assert.same({ "application/json" }, http._prepared)
        assert.equal("no-cache", http._headers["Cache-Control"])
        assert.equal(403, http._status[1].code)
        assert.matches("tail$", H.body())
    end)
end)

-- === nixio.fs fake ===

describe("nixio.fs fake", function()
    it("stats files, dirs and misses", function()
        H.begin()
        H.vfs_write("/etc/config/f.conf", "data")
        local nixio = H.reload("nixio")
        local st = nixio.fs.stat("/etc/config/f.conf")
        assert.truthy(st)
        assert.falsy(st.is_directory)
        H.state().dirs["/tmp/pt-dir"] = true
        local dst = nixio.fs.stat("/tmp/pt-dir")
        assert.truthy(dst and dst.is_directory)
        local sub = nixio.fs.stat("/tmp/pt-dir/file.txt")
        assert.truthy(sub and sub.is_directory)
        assert.is_nil(nixio.fs.stat("/etc/absent"))
    end)

    it("readfile works", function()
        H.begin()
        H.vfs_write("/tmp/rf.txt", "hello")
        local nixio = H.reload("nixio")
        assert.equal("hello", nixio.fs.readfile("/tmp/rf.txt"))
        assert.is_nil(nixio.fs.readfile("/tmp/gone"))
    end)
end)

-- === integration with real project modules ===

describe("harness integration", function()
    it("services roundtrip through overlay", function()
        H.begin()
        local SRV = H.reload("podkop-tweaker.services")
        local ok, err = SRV.write_file_atomic("/etc/config/podkop", "config main\n\toption x '1'\n")
        assert.truthy(ok, err)
        assert.equal("config main\n\toption x '1'\n", SRV.read_file("/etc/config/podkop"))

        local ops = { config = "/etc/config/podkop", backup = "/etc/config/podkop.auto-backup" }
        assert.truthy(SRV.backup_current(ops))
        assert.equal("config main\n\toption x '1'\n", SRV.read_file(ops.backup))

        H.vfs_write("/etc/config/podkop", "changed\n")
        assert.truthy(SRV.restore_backup(ops))
        assert.equal("config main\n\toption x '1'\n", SRV.read_file("/etc/config/podkop"))
    end)

    it("singbox_content_check branches", function()
        H.begin()
        local SRV = H.reload("podkop-tweaker.services")
        local ok, msg = SRV.singbox_content_check("", "empty!")
        assert.falsy(ok)
        assert.equal("empty!", msg)
        ok, msg = SRV.singbox_content_check(string.rep("x", 2097153), "")
        assert.falsy(ok)
        assert.matches("too large", msg)
        ok, msg = SRV.singbox_content_check("has\0byte", "")
        assert.falsy(ok)
        assert.matches("null bytes", msg)
        assert.truthy(SRV.singbox_content_check("{}", ""))
    end)

    it("clears loaded modules on begin", function()
        H.begin()
        assert.is_nil(package.loaded["podkop-tweaker.services"])
        assert.is_not_nil(require("podkop-tweaker.services"))
        H.finish()
        H.begin()
        assert.is_nil(package.loaded["podkop-tweaker.services"])
    end)
end)

-- === isolation ===

describe("isolation", function()
    it("restores globals and removes preloads after finish", function()
        local pristine_open = io.open
        local pristine_execute = os.execute
        local pristine_rename = os.rename
        H.begin()
        assert.not_equal(pristine_open, io.open)
        assert.not_equal(pristine_execute, os.execute)
        H.finish()
        assert.equal(pristine_open, io.open)
        assert.equal(pristine_execute, os.execute)
        assert.equal(pristine_rename, os.rename)
        for _, k in ipairs({ "luci.sys", "luci.model.uci", "luci.http", "luci.jsonc", "cjson", "nixio" }) do
            assert.is_nil(package.preload[k], k)
        end
    end)

    it("begin finishes previous session automatically", function()
        H.begin()
        local st1 = H.state()
        H.begin()
        assert.not_equal(st1, H.state())
        assert.equal(0, #H.exec_cmds())
    end)
end)
