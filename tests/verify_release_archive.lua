-- Run from repo: lua5.1 tests/verify_release_archive.lua ARCHIVE [TAG_OR_VERSION]
-- Read actual bytes and metadata; application/service writes stay in the VFS.
package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path
local H = require("pt_harness")
local LIB = require("podkop-tweaker.lib")
local SRV = require("podkop-tweaker.services")
local ARCH = require("podkop-tweaker.archive")
local source = assert(arg[1], "archive path required")
local controller = assert(SRV.read_file(ARCH.CONTROLLER, ARCH.MAX_FILE_SIZE))
local version = assert(controller:match('local%s+APP_VERSION%s*=%s*"([^"]+)"'), "source version missing")
local expected = (arg[2] or version):gsub("^v", "")
assert(version == expected, "release tag/source version mismatch")
assert(source:match("([^/]+)$") == "luci-app-podkop-tweaker-v" .. expected .. ".tar.gz", "non-canonical release filename")
local bytes = assert(SRV.read_file(source, 128000))
local pipe = assert(io.popen("gzip -dc " .. LIB.shell_escape(source)))
local tar, tar_err = SRV.read_stream(pipe, ARCH.MAX_STREAM_SIZE)
local closed = pipe:close()
assert(tar and closed, tar_err or "cannot decompress archive")
local manifest, inspect_err = ARCH.parse_tar(tar, false)
assert(manifest, inspect_err)

local inventory = assert(io.popen("git ls-files -- usr etc www"))
local names = assert(SRV.read_stream(inventory, 65536))
assert(inventory:close(), "cannot inspect source inventory")
local required = {}
for name in names:gmatch("[^\r\n]+") do required[name] = true end
assert(required[ARCH.CONTROLLER], "deployment inventory missing controller")
local payloads, count = {}, 0
for _, entry in ipairs(manifest.entries) do
    if entry.kind == "reg" then
        assert(required[entry.path], "unexpected release member: " .. entry.path)
        -- Local BSD tar adds ./; CI GNU tar uses bare names. The already-validated
        -- exact source inventory makes this suffix selector unambiguous.
        local member = assert(io.popen("tar --wildcards -xOzf " .. LIB.shell_escape(source) .. " " .. LIB.shell_escape("*" .. entry.path)))
        local content = assert(SRV.read_stream(member, ARCH.MAX_FILE_SIZE))
        assert(member:close(), "cannot read member: " .. entry.path)
        assert(#content == entry.size, "member size mismatch: " .. entry.path)
        assert(content == assert(SRV.read_file(entry.path, ARCH.MAX_FILE_SIZE)), "stale release member: " .. entry.path)
        if entry.path:match("^usr/bin/") or entry.path:match("^etc/init%.d/") then
            assert(not content:find("\r", 1, true), "executable script must use LF: " .. entry.path)
        end
        payloads[entry.path], required[entry.path] = content, nil
        count = count + 1
    end
end
assert(next(required) == nil, "release omits a deployable source file: " .. tostring(next(required)))

local tmp = "/tmp/pt-update"
H.begin({
    popen = function(command)
        if command:find("gzip -dc", 1, true) then return tar .. "\nPT_GZIP_EXIT:0\n" end
        return ""
    end,
    sys = { { match = "tar -xzf", out = function()
        for _, entry in ipairs(manifest.entries) do
            if entry.kind == "dir" then H.state().dirs[tmp .. "/" .. entry.path] = true
            else H.vfs_write(tmp .. "/" .. entry.path, payloads[entry.path]) end
        end
        return "\nPT_EXIT:0\n"
    end } }
})
local update = require("podkop-tweaker.api_update")
update.init("0.0.0")
local preview = update.upload_binary(bytes, "luci-app-podkop-tweaker-v" .. expected .. ".tar.gz")
assert(preview.success and preview.can_update and preview.archive_version == expected, "real binary upload validation failed")
update.init(expected)
H.vfs_write("/etc/config/podkop-tweaker", "saved appearance + unknown settings")
local applied = update.apply("1")
local preserved = H.vfs_read("/etc/config/podkop-tweaker") == "saved appearance + unknown settings"
H.finish()
assert(applied.success and applied.reinstalled and preserved, "real archive reinstall/UCI preservation failed")
print("Release archive: PASS (" .. #bytes .. " bytes, " .. #manifest.entries .. " members, " .. count .. " source-matched files, version " .. expected .. "; upload/reinstall in VFS)")
