-- Run from repo: lua5.1 tests/verify_release_archive.lua ARCHIVE [TAG_OR_VERSION] [INSTALLED_ARCHIVE]
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
local updater = assert(SRV.read_file("usr/lib/lua/podkop-tweaker/api_update.lua", ARCH.MAX_FILE_SIZE))
local upload_limit = assert(tonumber(updater:match("\nM%.UPLOAD_MAX_SIZE%s*=%s*(%d+)")), "source upload limit missing")
local bytes = assert(SRV.read_file(source, upload_limit))
local pipe = assert(io.popen("gzip -dc " .. LIB.shell_escape(source)))
local tar, tar_err = SRV.read_stream(pipe, ARCH.MAX_STREAM_SIZE)
local closed = pipe:close()
assert(tar and closed, tar_err or "cannot decompress archive")
local manifest, inspect_err = ARCH.parse_tar(tar, false)
assert(manifest, inspect_err)

-- Local candidates may include new, not-yet-staged source modules. CI uses the
-- same command in a clean checkout, where the inventory is entirely tracked.
local inventory = assert(io.popen("git ls-files --cached --others --exclude-standard -- usr etc www"))
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

-- Optional delivery check executes the actual installed receiver modules,
-- not the candidate's new upload/copy implementation. Only transport/processes
-- and filesystem are virtual; no network or router operation is performed.
-- Exact version equality requires explicit Local Reinstall; unforced Git is
-- checked only for newer candidates, never treated as an equal-version update.
local receiver_modules, receiver_version, receiver_git_limit, receiver_same_version
if arg[3] then
    local function read_member(name)
        local fd = assert(io.popen("tar --wildcards -xOzf " .. LIB.shell_escape(arg[3]) .. " " .. LIB.shell_escape("*" .. name)))
        local content = assert(SRV.read_stream(fd, ARCH.MAX_FILE_SIZE))
        assert(fd:close(), "cannot read installed receiver member: " .. name)
        return content
    end
    receiver_version = assert(read_member(ARCH.CONTROLLER):match('local%s+APP_VERSION%s*=%s*"([^"]+)"'), "installed version missing")
    receiver_same_version = receiver_version == expected
    receiver_modules = {}
    for _, name in ipairs({ "lib", "services", "net", "archive", "web_restart", "api_update" }) do
        local module_name = "podkop-tweaker." .. name
        local content = read_member("usr/lib/lua/podkop-tweaker/" .. name .. ".lua")
        receiver_modules[module_name] = assert(loadstring(content, "@installed/" .. name .. ".lua"))
        if name == "api_update" then
            receiver_git_limit = assert(tonumber(content:match("NET%.fetch%(%s*download_url%s*,%s*(%d+)")), "installed Git limit missing")
        end
    end
    receiver_modules["pt-subs-lib"] = assert(loadstring(read_member("usr/lib/lua/pt-subs-lib.lua"), "@installed/pt-subs-lib.lua"))
    assert(#bytes <= receiver_git_limit, "candidate exceeds the installed Git download limit")
end

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
assert(update.UPLOAD_MAX_SIZE == upload_limit, "source/runtime upload limit mismatch")
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

if receiver_modules then
    -- Fixed internal cleanup paths may be quoted or inside a checked shell
    -- wrapper. A recorded request matters even when the VFS does not model rm.
    local function requests_staging_cleanup(command, staged)
        for body in command:gsub("['\"]", ""):gmatch("[^;&|()\n]+") do
            local operation, args = body:match("^%s*(%S+)%s+(.*)")
            operation = operation and operation:match("([^/]+)$")
            if operation == "exec" or operation == "busybox" then
                operation, args = args:match("^(%S+)%s+(.*)")
                operation = operation and operation:match("([^/]+)$")
            end
            if operation == "rm" or operation == "rmdir" or operation == "remove" then
                for target in args:gmatch("[^%s<>]+") do
                    target = target:gsub("/+$", ""):gsub("/%.$", "")
                    local prefix = target:match("^(.-)%*") or target:match("^(.-)%?") or target:match("^(.-)%[")
                    for path in pairs(staged) do
                        if path == target or path:sub(1, #target + 1) == target .. "/" or
                            prefix and prefix:sub(1, 1) == "/" and path:sub(1, #prefix) == prefix then
                            return true
                        end
                    end
                end
            end
        end
        return false
    end
    local url = "https://github.com/InsaniaQuon/luci-app-podkop-tweaker/releases/download/v" .. expected ..
        "/luci-app-podkop-tweaker-v" .. expected .. ".tar.gz"
    local transports = receiver_same_version and { "local" } or { "local", "git" }
    for _, transport in ipairs(transports) do
        local tmp_dir, downloads = transport == "local" and "/tmp/pt-update" or "/tmp/pt-git-update", 0
        H.begin({
            popen = function(command)
                if command:find("gzip -dc", 1, true) then return tar .. "\nPT_GZIP_EXIT:0\n" end
                if command:find("curl", 1, true) and command:find(LIB.shell_escape(url), 1, true) then
                    downloads = downloads + 1
                    return bytes .. "\nPT_CURL_EXIT:0\n"
                end
            end,
            sys = { { match = "tar -xzf", out = function()
                for _, entry in ipairs(manifest.entries) do
                    if entry.kind == "dir" then H.state().dirs[tmp_dir .. "/" .. entry.path] = true
                    else H.vfs_write(tmp_dir .. "/" .. entry.path, payloads[entry.path]) end
                end
                return "\nPT_EXIT:0\n"
            end } }
        })
        for name, chunk in pairs(receiver_modules) do package.preload[name] = chunk end
        local installed = require("podkop-tweaker.api_update")
        installed.init(receiver_version)
        if receiver_same_version then
            assert(#bytes <= installed.UPLOAD_MAX_SIZE, "candidate exceeds the installed Local Reinstall upload limit")
        else
            assert(require("podkop-tweaker.lib").version_lt(receiver_version, expected), "installed receiver does not consider candidate newer")
        end
        local saved = {
            ["etc/config/podkop-tweaker"] = "config settings 'settings'\n\toption show_argon_tab '1'\n\toption unknown 'retain'\n" ..
                "config appearance 'appearance'\n\toption profile 'contrast'\n\toption mono_font_size '17'\n\toption color_success_light '#123456'\n\toption unknown_appearance 'retain'\n",
            ["etc/config/podkop-fragment"] = "config fragment 'settings'\n\toption enabled '0'\n\toption fragment 'false'\n\toption record_fragment 'true'\n" ..
                "\toption fragment_fallback_delay '750ms'\n\toption singbox_config '/custom/config.json'\n\toption log_file '/custom/fragment.log'\n\toption log_max_lines '317'\n\toption unknown 'retain'\n"
        }
        for path, content in pairs(saved) do H.vfs_write("/" .. path, content) end
        if transport == "local" and #bytes > installed.UPLOAD_MAX_SIZE then
            assert(installed.upload_binary(bytes, "luci-app-podkop-tweaker-v" .. expected .. ".tar.gz").error == "Invalid archive",
                "installed Local Update boundary was not retained")
            assert(#H.exec_cmds() == 0 and #H.execute_cmds() == 0, "oversized Local upload mutated installed state")
            H.finish()
            print("Installed Local boundary: PASS (candidate above installed cap is rejected before mutation)")
        else
            local result
            if transport == "local" then
                local preview = installed.upload_binary(bytes, "luci-app-podkop-tweaker-v" .. expected .. ".tar.gz")
                if receiver_same_version then
                    assert(preview.success == true and preview.same_version == true and preview.can_update == false and
                        preview.current_version == receiver_version and preview.archive_version == expected,
                        "installed receiver same-version Local preview failed")
                    local before = {}
                    for path in pairs(payloads) do before[path] = H.vfs_read("/" .. path) end
                    local staged = {}
                    for path in pairs(H.state().vfs) do
                        if path:sub(1, #tmp_dir + 1) == tmp_dir .. "/" then staged[path] = H.vfs_read(path) end
                    end
                    local command_logs = {
                        { source = "sys.exec", commands = H.exec_cmds() },
                        { source = "os.execute", commands = H.execute_cmds() },
                        { source = "io.popen", commands = H.popen_cmds() }
                    }
                    for _, log in ipairs(command_logs) do log.before = #log.commands end
                    local rejected = installed.apply()
                    assert(not rejected.success and not rejected.applied and rejected.error == "Archive version is not newer than installed",
                        "installed receiver accepted equal-version Local apply without explicit reinstall")
                    for path in pairs(payloads) do
                        assert(H.vfs_read("/" .. path) == before[path], "equal-version default apply changed installed bytes: " .. path)
                    end
                    assert(H.vfs_exists(tmp_dir .. "/.pt-manifest.json"), "equal-version rejection discarded validated staging")
                    for path, content in pairs(staged) do
                        assert(H.vfs_read(path) == content, "equal-version default apply changed validated staging bytes: " .. path)
                    end
                    for _, log in ipairs(command_logs) do
                        for index = log.before + 1, #log.commands do
                            local command = log.commands[index]
                            assert(not requests_staging_cleanup(command, staged),
                                "equal-version default apply requested staging cleanup via " .. log.source .. ": " .. command)
                        end
                        for _, command in ipairs(log.commands) do
                            assert(not command:find("uhttpd restart", 1, true), "equal-version default apply requested a web restart")
                        end
                    end
                    result = installed.apply("1")
                else
                    assert(preview.success and preview.can_update and not preview.same_version, "installed receiver Local preview failed")
                    result = installed.apply()
                end
            else result = installed.git_update(url) end
            assert(result.success and result.new_version == expected, "installed receiver " .. transport .. " application failed: " .. tostring(result.error) .. " " .. tostring(result.details))
            if receiver_same_version then assert(result.reinstalled == true, "installed receiver did not report explicit Local Reinstall") end
            assert(downloads == (transport == "git" and 1 or 0), "installed receiver used an unexpected download")
            for path, content in pairs(payloads) do
                assert(H.vfs_read("/" .. path) == (saved[path] or content), "installed receiver lost source/settings bytes: " .. path)
            end
            H.finish()
            local delivery = receiver_same_version and "local explicit Reinstall; same-version preview/default rejection verified" or transport
            print("Installed receiver: PASS (" .. receiver_version .. " -> " .. expected .. ", " .. delivery .. ", " .. #bytes .. " bytes" ..
                "; source-matched files and both full UCI preserved; VFS, no live network/router)")
        end
    end
    if receiver_same_version then
        print("Installed Git equality: SKIP (unforced equal-version update is not supported; use explicit Local Reinstall)")
    end
end
