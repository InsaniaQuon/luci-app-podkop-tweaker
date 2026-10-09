-- Self-update integration with real tar metadata fixtures and VFS fault injection.
package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path
local H = require("pt_harness")
local T = require("pt_tar")
local C = "usr/lib/lua/luci/controller/podkop-tweaker.lua"
local TMP, GTMP, CACHE = "/tmp/pt-update", "/tmp/pt-git-update", "/tmp/tweaker_check_cache.json"
local NAME = "luci-app-podkop-tweaker-v4.7.0.tar.gz"
local URL = "https://github.com/InsaniaQuon/luci-app-podkop-tweaker/releases/download/v4.7.0/" .. NAME
local CTRL = 'local APP_VERSION = "4.7.0"\n'
local ORPHAN = "/usr/lib/lua/luci/view/podkop-tweaker/podkop-tweaker-css.htm"
local FILES = {
    { path = C, content = CTRL },
    { path = "usr/lib/lua/podkop-tweaker/lib.lua", content = "module" },
    { path = "www/luci-static/resources/podkop-tweaker/common.js", content = "new JS" },
    { path = "etc/config/podkop-tweaker", content = "defaults" },
    { path = "usr/bin/podkop-fragment-patch.sh", content = "script" }
}

local function begin(options)
    options = options or {}
    local entries = options.entries or FILES
    local tar = options.tar or T.archive(entries)
    local dir = options.git and GTMP or TMP
    local sys = options.sys or {}
    sys[#sys + 1] = { match = "tar -xzf", out = function()
        if options.extract_fail then return "tar failed\nPT_EXIT:1\n" end
        for _, entry in ipairs(entries) do
            local path = entry.path:gsub("^%./", ""):gsub("/$", "")
            if entry.kind == "5" then H.state().dirs[dir .. "/" .. path] = true
            else H.vfs_write(dir .. "/" .. path, entry.content or "") end
        end
        if options.after_extract then options.after_extract(dir) end
        return "\nPT_EXIT:0\n"
    end }
    H.begin({ sys = sys, failures = options.failures, execute = options.execute,
        popen = function(cmd)
            if cmd:find("gzip -dc", 1, true) then return tar .. "\nPT_GZIP_EXIT:" .. (options.gzip_fail and "1" or "0") .. "\n" end
            if cmd:find("curl", 1, true) then return (options.download or "archive") .. "\nPT_CURL_EXIT:" .. tostring(options.curl_exit or 0) .. "\n" end
            return ""
        end })
    local update = require("podkop-tweaker.api_update")
    update.init("4.6.0")
    return update
end
local function has_command(part)
    for _, cmd in ipairs(H.exec_cmds()) do if cmd:find(part, 1, true) then return true end end
    return false
end
local function prepare(update)
    assert.is_true(update.upload_binary("archive", NAME).success)
end
after_each(function() H.finish() end)

describe("update metadata and application", function()
    it("accepts a bounded archive, writes a manifest and compares versions", function()
        local update = begin()
        assert.same({ success = true, current_version = "4.6.0", archive_version = "4.7.0", can_update = true, same_version = false }, update.upload_binary("archive", NAME))
        assert.truthy(H.vfs_exists(TMP .. "/.pt-manifest.json"))
        assert.equal("archive", H.vfs_read(TMP .. "/upload.tar.gz"))
    end)
    it("retains legacy base64 errors and enforces the compressed limit before writes", function()
        local update = begin()
        assert.same({ error = "No file uploaded" }, update.upload("", NAME))
        assert.same({ error = "Invalid archive" }, update.upload("!@#", NAME))
        assert.same({ error = "Invalid archive" }, update.upload_binary(string.rep("x", 128001), NAME))
        assert.same({ error = "Invalid archive" }, update.upload_binary("x", "backup.tar.gz"))
        assert.equal(0, #H.exec_cmds())
    end)
    it("handles a binary archive larger than LuCI's text buffer", function()
        local update = begin()
        local bytes = "\31\139" .. string.rep("\0\255", 55000)
        assert.is_true(update.upload_binary(bytes, NAME).success)
        assert.equal(bytes, H.vfs_read(TMP .. "/upload.tar.gz"))
    end)
    it("rejects type, path, size, checksum and gzip failures before extraction", function()
        local bad = {
            T.archive({ { path = C, kind = "6" } }),
            T.archive({ { path = C, kind = "2", options = { link = "/etc/passwd" } } }),
            T.archive({ { path = C }, { path = "../etc/shadow" } }),
            T.archive({ { path = C }, { path = "usr/lib/lua/a';printf marker;#/x.lua" } }),
            T.archive({ { path = C, options = { size = 1048577 } } }), "bad tar"
        }
        for _, tar in ipairs(bad) do
            local update = begin({ tar = tar })
            assert.equal("Invalid archive", update.upload_binary("archive", NAME).error)
            assert.is_false(has_command("tar -xzf"))
            H.finish()
        end
        local update = begin({ gzip_fail = true })
        assert.equal("Invalid archive", update.upload_binary("archive", NAME).error)
        assert.is_false(has_command("tar -xzf"))
    end)
    it("requires extraction success and matches extracted types/sizes before reading controller", function()
        local update = begin({ extract_fail = true })
        assert.equal("Invalid archive", update.upload_binary("archive", NAME).error)
        H.finish()
        update = begin({ after_extract = function(dir) H.state().vfs[dir .. "/" .. C].type = "fifo" end })
        assert.equal("Invalid archive", update.upload_binary("archive", NAME).error)
        for _, call in ipairs(H.state().io_log) do assert.falsy(call.operation == "open" and call.path == TMP .. "/" .. C) end
    end)
    it("requires a staged manifest and rejects a changed controller", function()
        local update = begin()
        assert.equal("No archive uploaded", update.apply().error)
        prepare(update)
        H.vfs_write(TMP .. "/" .. C, 'local APP_VERSION = "4.9.0"\n')
        assert.equal("Invalid archive", update.apply().error)
        assert.is_false(has_command("uhttpd restart"))
    end)
    it("preserves app configuration, copies all other files, removes orphans and restarts on complete success", function()
        local update = begin()
        prepare(update)
        H.vfs_write("/etc/config/podkop-tweaker", "user appearance + unknown options")
        H.vfs_write(ORPHAN, "old")
        local response = update.apply()
        assert.same({ success = true, new_version = "4.7.0", files_copied = #FILES - 1 }, response)
        assert.equal(CTRL, H.vfs_read("/" .. C))
        assert.equal("user appearance + unknown options", H.vfs_read("/etc/config/podkop-tweaker"))
        assert.falsy(H.vfs_exists(ORPHAN))
        assert.is_true(has_command("uhttpd restart"))
        assert.is_true(has_command("luci-modulecache"))
        local chmod = false
        for _, cmd in ipairs(H.execute_cmds()) do if cmd:find("chmod 755", 1, true) then chmod = true end end
        assert.is_true(chmod)
    end)
    it("shows exact equality but rejects an equal-version apply without explicit reinstall", function()
        local update = begin()
        update.init("4.7.0")
        local preview = update.upload_binary("archive", NAME)
        assert.is_true(preview.same_version)
        assert.is_false(preview.can_update)
        assert.equal("Archive version is not newer than installed", update.apply().error)
        assert.is_false(has_command("uhttpd restart"))
        assert.truthy(H.vfs_exists(TMP .. "/.pt-manifest.json"))
    end)
    it("explicit reinstall applies equal-version files through the checked pipeline and preserves app settings", function()
        local update = begin()
        update.init("4.7.0")
        prepare(update)
        H.vfs_write("/etc/config/podkop-tweaker", "saved colors + unknown options")
        local response = update.apply("1")
        assert.same({ success = true, reinstalled = true, new_version = "4.7.0", files_copied = #FILES - 1 }, response)
        assert.equal("saved colors + unknown options", H.vfs_read("/etc/config/podkop-tweaker"))
        assert.equal(CTRL, H.vfs_read("/" .. C))
        assert.is_true(has_command("uhttpd restart"))
    end)
    it("reinstall cannot authorize older, newer or differently labeled same-core versions", function()
        for _, installed in ipairs({ "4.8.0", "4.6.0", "4.7.0-other" }) do
            local update = begin()
            update.init(installed)
            local preview = update.upload_binary("archive", NAME)
            assert.is_false(preview.same_version)
            assert.equal("Reinstall is only allowed for the exact installed version", update.apply("1").error)
            assert.is_false(has_command("uhttpd restart"))
            H.finish()
        end
    end)
    it("older archives remain rejected by ordinary apply", function()
        local update = begin()
        update.init("4.8.0")
        prepare(update)
        assert.equal("Archive version is not newer than installed", update.apply().error)
        assert.is_false(has_command("uhttpd restart"))
    end)
    it("unrecognized reinstall flags do not bypass equality gating", function()
        local update = begin()
        update.init("4.7.0")
        prepare(update)
        for _, flag in ipairs({ "0", "true", true, 1 }) do
            assert.equal("Archive version is not newer than installed", update.apply(flag).error)
        end
        assert.is_false(has_command("uhttpd restart"))
    end)
    it("reinstall does not bypass a changed manifest member or application failure", function()
        local update = begin({ failures = { ["/www/luci-static/resources/podkop-tweaker/common.js.tmp-update"] = { close = true } } })
        update.init("4.7.0")
        prepare(update)
        local response = update.apply("1")
        assert.is_false(response.success)
        assert.is_true(response.staging_retained)
        assert.is_false(has_command("uhttpd restart"))
        H.finish()
        update = begin()
        update.init("4.7.0")
        prepare(update)
        H.vfs_write(TMP .. "/" .. C, 'local APP_VERSION = "4.9.0"\n')
        assert.equal("Invalid archive", update.apply("1").error)
        assert.is_false(has_command("uhttpd restart"))
    end)
    for _, failure in ipairs({ "open", "write", "close", "rename" }) do
        local kind = failure
        it("does not report success, clean staging or restart after " .. kind .. " failure", function()
            local dest = "/www/luci-static/resources/podkop-tweaker/common.js"
            local faults = { [kind == "rename" and dest or dest .. ".tmp-update"] = { [kind] = true, partial = 2 } }
            local update = begin({ failures = faults })
            prepare(update)
            H.vfs_write(dest, "old JS")
            H.vfs_write(ORPHAN, "old")
            local commands_before = #H.exec_cmds()
            local response = update.apply()
            assert.is_false(response.success)
            assert.is_true(response.staging_retained)
            assert.matches("common.js", response.details)
            assert.equal("old JS", H.vfs_read(dest))
            assert.truthy(H.vfs_exists(ORPHAN))
            assert.truthy(H.vfs_exists(TMP .. "/.pt-manifest.json"))
            for i = commands_before + 1, #H.exec_cmds() do
                assert.falsy(H.exec_cmds()[i]:find("rm -rf", 1, true))
                assert.falsy(H.exec_cmds()[i]:find("uhttpd restart", 1, true))
            end
        end)
    end
    it("aborts on missing manifest member, directory failure and chmod failure", function()
        local update = begin()
        prepare(update)
        H.state().vfs[TMP .. "/usr/lib/lua/podkop-tweaker/lib.lua"] = nil
        assert.equal("Invalid archive", update.apply().error)
        H.finish()
        update = begin({ execute = { { match = "chmod", out = 1 } } })
        prepare(update)
        assert.is_false(update.apply().success)
        H.finish()
        update = begin()
        prepare(update)
        H.state().sys_scripts[#H.state().sys_scripts + 1] = { match = "mkdir -p '/usr/lib/lua/luci/controller'", out = "\nPT_EXIT:1\n" }
        assert.is_false(update.apply().success)
    end)
end)

describe("trusted Git update source", function()
    it("rejects foreign routes, dot segments, encoded paths and URL globbing before curl", function()
        local update = begin({ git = true })
        for _, bad in ipairs({
            "https://evil.test/a.tar.gz", "https://github.com/InsaniaQuon/luci-app-podkop-tweaker/../../evil/releases/download/v4.7.0/a.tar.gz",
            URL .. "?redirect=evil", URL:gsub("download", "%%2e%%2e"), URL:gsub("v4.7.0", "v4.{6,7}.0"),
            "http://github.com/InsaniaQuon/luci-app-podkop-tweaker/releases/download/v4.7.0/a.tar.gz"
        }) do assert.equal("Invalid download URL", update.git_update(bad).error) end
        assert.equal(0, #H.popen_cmds())
        assert.equal("Download URL is required", update.git_update("").error)
    end)
    it("keeps force downgrade and future safe paths working", function()
        local entries = { { path = C, content = 'local APP_VERSION = "4.5.0"\n' }, { path = "usr/share/future/file.txt", content = "new" } }
        local update = begin({ git = true, entries = entries })
        assert.equal("Archive version is not newer than installed", update.git_update(URL).error)
        assert.is_false(has_command("uhttpd restart"))
        H.finish()
        update = begin({ git = true, entries = entries })
        H.vfs_write(CACHE, "cache")
        assert.same({ success = true, new_version = "4.5.0", files_copied = 2 }, update.git_update(URL, "1"))
        assert.equal("new", H.vfs_read("/usr/share/future/file.txt"))
        assert.falsy(H.vfs_exists(CACHE))
    end)
    it("enforces compressed download limits and rejects malformed archives before extraction", function()
        local update = begin({ git = true, download = string.rep("x", 512001) })
        assert.equal("Archive too large", update.git_update(URL).error)
        assert.is_false(has_command("tar -xzf"))
        H.finish()
        update = begin({ git = true, curl_exit = 18 })
        assert.equal("Failed to download archive", update.git_update(URL).error)
        H.finish()
        update = begin({ git = true, entries = { { path = C, kind = "1", options = { link = "/etc/passwd" } } } })
        assert.equal("Invalid archive", update.git_update(URL).error)
        assert.is_false(has_command("tar -xzf"))
    end)
end)

describe("update cache and logs", function()
    it("handles missing, fresh, expired and malformed cache", function()
        local update = begin()
        assert.is_nil(update.cached_latest())
        H.vfs_write(CACHE, '{"latest_version":"4.7.0","cached_at":' .. os.time() .. '}')
        assert.equal("4.7.0", update.cached_latest())
        assert.equal("rate_limited", update.check_update().error)
        H.vfs_write(CACHE, '{"latest_version":"4.7.0","cached_at":' .. (os.time() - 90000) .. '}')
        assert.is_nil(update.cached_latest())
        H.vfs_write(CACHE, "invalid")
        assert.is_nil(update.cached_latest())
    end)
    it("checks GitHub, compares versions, writes cache and force rechecks", function()
        local raw = '{"tag_name":"v4.7.0","assets":[{"browser_download_url":"' .. URL .. '"}]}'
        local update = begin({ sys = { { match = "api.github.com", out = raw } } })
        assert.equal("4.7.0", update.check_update().latest_version)
        assert.equal("rate_limited", update.check_update().error)
        assert.equal(URL, update.check_update_force().download_url)
    end)
    it("restores fresh safe download metadata and never exposes foreign or expired URLs", function()
        local update = begin()
        H.vfs_write(CACHE, H.json.stringify({ latest_version = "4.7.0", download_url = URL, cached_at = os.time() }))
        assert.same({ latest_version = "4.7.0", download_url = URL, current_version = "4.6.0", update_available = true }, update.cached_update())
        H.vfs_write(CACHE, H.json.stringify({ latest_version = "4.7.0", download_url = "https://evil.test/update.tar.gz", cached_at = os.time() }))
        assert.equal("", update.cached_update().download_url)
        H.vfs_write(CACHE, H.json.stringify({ latest_version = "4.7.0", download_url = URL, cached_at = os.time() - 90000 }))
        assert.is_nil(update.cached_update())
        H.vfs_write(CACHE, H.json.stringify({ latest_version = "4.7.0", download_url = URL, cached_at = os.time() + 100 }))
        assert.is_nil(update.cached_update())
    end)
    it("reports connection, parse and GitHub rate-limit errors", function()
        for _, raw in ipairs({ "", "invalid", '{"message":"API rate limit exceeded"}' }) do
            local update = begin({ sys = { { match = "api.github.com", out = raw } } })
            assert.truthy(update.check_update().error)
            H.finish()
        end
    end)
    it("clears cache and restarts only when requested; reads complete log lines", function()
        local update = begin()
        assert.same({ lines = {} }, update.read_log())
        H.vfs_write("/etc/config/pt-update.log", "one\ntwo\n")
        assert.same({ lines = { "one", "two" } }, update.read_log())
        H.vfs_write(CACHE, "cache")
        assert.same({ success = true }, update.clear_cache())
        assert.falsy(H.vfs_exists(CACHE))
        assert.is_true(has_command("uhttpd restart"))
    end)
    it("does not queue a restart when cache cleanup fails", function()
        local update = begin({ execute = { { match = "rm -rf /tmp/luci-", out = 1 } } })
        assert.equal("Cannot clear LuCI caches", update.clear_cache().error)
        assert.is_false(has_command("uhttpd restart"))
    end)
end)
