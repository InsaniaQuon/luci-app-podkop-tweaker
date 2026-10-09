package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path
local A = require("podkop-tweaker.archive")
local T = require("pt_tar")
local C = "usr/lib/lua/luci/controller/podkop-tweaker.lua"

describe("archive metadata preflight", function()
    it("accepts normal root/directory members and regular application files", function()
        local manifest = assert(A.parse_tar(T.archive({
            { path = "./", kind = "5" }, { path = "./usr/", kind = "5" },
            { path = "./" .. C, content = 'local APP_VERSION = "4.6.0"\n' }
        }), false))
        assert.equal(2, #manifest.entries)
        assert.equal(C, manifest.entries[2].path)
    end)
    for _, kind in ipairs({ "1", "2", "3", "4", "6", "S" }) do
        local value = kind
        it("rejects non-regular member type " .. value .. " without extraction", function()
            local manifest, err = A.parse_tar(T.archive({ { path = C, kind = value, options = { link = "/etc/passwd" } } }), false)
            assert.is_nil(manifest)
            assert.matches("regular files", err)
        end)
    end
    for _, path in ipairs({ "../etc/passwd", "/etc/shadow", "usr/lib/lua/a';printf MARK;#/x.lua", "usr/lib/lua/other.lua", "usr/lib/lua/a\nb.lua" }) do
        local value = path
        it("rejects an unsafe or foreign strict path", function()
            assert.is_nil(A.parse_tar(T.archive({ { path = C }, { path = value } }), false))
        end)
    end
    it("rejects a large member from its header before reading its payload", function()
        local manifest, err = A.parse_tar(T.archive({ { path = C, options = { size = A.MAX_FILE_SIZE + 1 } } }), false)
        assert.is_nil(manifest)
        assert.matches("member is too large", err)
    end)
    it("rejects excessive expanded size", function()
        local entries = { { path = C, content = "x" } }
        for i = 1, 4 do entries[#entries + 1] = { path = "usr/lib/lua/podkop-tweaker/f" .. i .. ".lua", content = string.rep("x", A.MAX_FILE_SIZE) } end
        local manifest, err = A.parse_tar(T.archive(entries), false)
        assert.is_nil(manifest)
        assert.matches("expanded size", err)
    end)
    it("rejects excessive member count", function()
        local entries = { { path = C } }
        for i = 1, A.MAX_MEMBERS do entries[#entries + 1] = { path = "usr/lib/lua/podkop-tweaker/f" .. i .. ".lua" } end
        assert.is_nil(A.parse_tar(T.archive(entries), false))
    end)
    it("rejects duplicate paths, bad checksum, truncated stream and missing controller", function()
        assert.is_nil(A.parse_tar(T.archive({ { path = C }, { path = C } }), false))
        local tar = T.archive({ { path = C } })
        assert.is_nil(A.parse_tar("!" .. tar:sub(2), false))
        assert.is_nil(A.parse_tar(tar:sub(1, -513), false))
        assert.is_nil(A.parse_tar(T.archive({ { path = "usr/lib/lua/podkop-tweaker/lib.lua" } }), false))
    end)
    it("supports safe PAX paths/mtime and rejects linkpath and traversal overrides", function()
        local meta = T.pax("mtime", "1.123") .. T.pax("path", C)
        assert.truthy(A.parse_tar(T.archive({ { path = "PaxHeader", kind = "x", content = meta }, { path = "placeholder.lua", content = "x" } }), false))
        for _, bad in ipairs({ T.pax("path", "../evil.lua"), T.pax("linkpath", "/etc/passwd"), T.pax("size", tostring(A.MAX_FILE_SIZE + 1)) }) do
            assert.is_nil(A.parse_tar(T.archive({ { path = "PaxHeader", kind = "x", content = bad }, { path = C } }), false))
        end
    end)
    it("keeps trusted Git namespaces future-proof but still rejects path/control metacharacters", function()
        assert.is_true(A.is_valid_path("usr/share/future/app.txt", true))
        for _, bad in ipairs({ "../app.txt", "/tmp/app.txt", "tmp/a'b.lua", "tmp/x\\y.lua", "tmp//x.lua" }) do assert.is_false(A.is_valid_path(bad, true)) end
    end)
end)
