-- api_update_spec | v1.0.0 | 23.08.2026 | Max-coverage specs for V2 pure handlers of api_update

package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path

local H = require("pt_harness")

local CACHE = "/tmp/tweaker_check_cache.json"
local TMP = "/tmp/pt-update"
local GTMP = "/tmp/pt-git-update"
local CTRL_REL = "usr/lib/lua/luci/controller/podkop-tweaker.lua"
local LOG = "/etc/config/pt-update.log"

local GITHUB_OK = '{"tag_name":"v4.9.9","assets":[{"browser_download_url":' ..
    '"https://github.com/InsaniaQuon/luci-app-podkop-tweaker/releases/download/v4.9.9/x.tar.gz"}]}'
local GITHUB_RATE = '{"message":"API rate limit exceeded for client"}'

local STRICT_FILES = {
    "usr/lib/lua/luci/controller/podkop-tweaker.lua",
    "usr/lib/lua/podkop-tweaker/lib.lua",
    "www/luci-static/resources/podkop-tweaker/common.js",
    "etc/config/podkop-tweaker"
}

local function b64(data)
    local B = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        out[#out + 1] = B:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
        out[#out + 1] = B:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
        out[#out + 1] = (b and B:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or "=")
        out[#out + 1] = (c and B:sub(n % 64 + 1, n % 64 + 1) or "=")
    end
    return table.concat(out)
end

local function ctrl_content(ver)
    if ver == nil then return "-- no version here\n" end
    return '-- controller\nlocal APP_VERSION = "' .. ver .. '"\n'
end

local function find_out(dir, rels)
    local lines = {}
    for _, r in ipairs(rels) do lines[#lines + 1] = dir .. "/" .. r end
    return { match = "find '", out = table.concat(lines, "\n") }
end

-- responder for the pre-extraction member check (tar -tzf)
local function tar_list_out(rels)
    local lines = {}
    for _, r in ipairs(rels) do lines[#lines + 1] = "./" .. r end
    return { match = "tar -tzf", out = table.concat(lines, "\n") }
end

local function seed_tree(dir, rels, ver)
    for _, r in ipairs(rels) do
        H.vfs_write(dir .. "/" .. r, (r == CTRL_REL) and ctrl_content(ver) or "data")
    end
end

local function begin_upd(opts)
    H.begin(opts)
    local UPD = H.reload("podkop-tweaker.api_update")
    UPD.init("4.1.0")
    return UPD
end

after_each(function()
    H.finish()
end)

describe("api_update.cached_latest", function()
    it("nil without cache file", function()
        local UPD = begin_upd({})
        assert.is_nil(UPD.cached_latest())
    end)

    it("returns latest when cache fresh", function()
        local UPD = begin_upd({})
        H.vfs_write(CACHE, '{"latest_version":"4.5.0","cached_at":' .. (os.time() - 10) .. '}')
        assert.equal("4.5.0", UPD.cached_latest())
    end)

    it("nil when cache expired or malformed", function()
        local UPD = begin_upd({})
        H.vfs_write(CACHE, '{"latest_version":"4.5.0","cached_at":' .. (os.time() - 1000) .. '}')
        assert.is_nil(UPD.cached_latest())
        H.finish()
        local UPD2 = begin_upd({})
        H.vfs_write(CACHE, "garbage")
        assert.is_nil(UPD2.cached_latest())
    end)
end)

describe("api_update.upload", function()
    local GOOD_NAME = "luci-app-podkop-tweaker-v4.3.0.tar.gz"

    it("missing data rejected", function()
        local UPD = begin_upd({})
        assert.same({ error = "No file uploaded" }, UPD.upload("", GOOD_NAME))
    end)

    it("undecodable b64 rejected", function()
        local UPD = begin_upd({})
        assert.same({ error = "Invalid archive" }, UPD.upload("!@@#", GOOD_NAME))
    end)

    it("oversize payload rejected", function()
        local UPD = begin_upd({})
        assert.same({ error = "Invalid archive" }, UPD.upload(b64(string.rep("a", 130001)), GOOD_NAME))
    end)

    it("wrong filename pattern rejected", function()
        local UPD = begin_upd({})
        assert.same({ error = "Invalid archive" }, UPD.upload(b64("bin"), "backup.tar.gz"))
    end)

    it("happy: version compared against installed", function()
        local UPD = begin_upd({ sys = { tar_list_out(STRICT_FILES), find_out(TMP, STRICT_FILES) } })
        seed_tree(TMP, STRICT_FILES, "4.3.0")
        local r = UPD.upload(b64("binary"), GOOD_NAME)
        assert.same({
            success = true,
            current_version = "4.1.0",
            archive_version = "4.3.0",
            can_update = true,
            same_version = false
        }, r)
        local cmds = H.exec_cmds()
        assert.equal("rm -rf /tmp/pt-update 2>/dev/null", cmds[1])
        assert.equal("mkdir -p /tmp/pt-update 2>/dev/null", cmds[2])
        -- member list is validated (tar -tzf) BEFORE extraction (tar -xzf)
        assert.truthy(cmds[3]:find("^tar %-tzf"))
        assert.truthy(cmds[4]:find("^cd /tmp/pt%-update && tar %-xzf upload%.tar%.gz"))
    end)

    it("controller missing after extract -> cleanup + invalid", function()
        local UPD = begin_upd({
            sys = {
                tar_list_out({ "usr/lib/lua/podkop-tweaker/lib.lua" }),
                find_out(TMP, { "usr/lib/lua/podkop-tweaker/lib.lua" })
            }
        })
        H.vfs_write(TMP .. "/usr/lib/lua/podkop-tweaker/lib.lua", "x")
        assert.same({ error = "Invalid archive" },
            UPD.upload(b64("bin"), "luci-app-podkop-tweaker-v4.3.0.tar.gz"))
        local cleanups = 0
        for _, c in ipairs(H.exec_cmds()) do
            if c == "rm -rf /tmp/pt-update 2>/dev/null" then cleanups = cleanups + 1 end
        end
        -- initial rm -rf + error-path cleanup
        assert.equal(2, cleanups)
    end)

    it("strict whitelist violation -> rejected before extraction (M1)", function()
        local rels = { CTRL_REL, "etc/shadow" }
        local UPD = begin_upd({ sys = { tar_list_out(rels), find_out(TMP, rels) } })
        seed_tree(TMP, rels, "4.3.0")
        assert.same({ error = "Invalid archive" },
            UPD.upload(b64("bin"), "luci-app-podkop-tweaker-v4.3.0.tar.gz"))
        -- dangerous members must never reach tar -xzf
        for _, c in ipairs(H.exec_cmds()) do
            assert.falsy(c:find("tar -xzf", 1, true))
        end
    end)

    it("empty member list rejected before extraction", function()
        local UPD = begin_upd({ sys = {} })
        assert.same({ error = "Invalid archive" },
            UPD.upload(b64("bin"), "luci-app-podkop-tweaker-v4.3.0.tar.gz"))
        for _, c in ipairs(H.exec_cmds()) do
            assert.falsy(c:find("tar -xzf", 1, true))
        end
    end)

    it("version line missing in controller -> cleanup + invalid", function()
        local rels = { CTRL_REL }
        local UPD = begin_upd({ sys = { tar_list_out(rels), find_out(TMP, rels) } })
        seed_tree(TMP, rels, nil)
        assert.same({ error = "Invalid archive" },
            UPD.upload(b64("bin"), "luci-app-podkop-tweaker-v4.3.0.tar.gz"))
    end)
end)

describe("api_update.apply", function()
    it("no extracted dir -> exact error", function()
        local UPD = begin_upd({})
        assert.same({ error = "No archive uploaded" }, UPD.apply())
    end)

    it("unreadable version -> cleanup + invalid", function()
        local rels = { CTRL_REL }
        local UPD = begin_upd({ sys = { find_out(TMP, rels) } })
        seed_tree(TMP, rels, nil)
        assert.same({ error = "Invalid archive" }, UPD.apply())
        assert.truthy(H.exec_cmds()[#H.exec_cmds()]:find("rm %-rf /tmp/pt%-update"))
    end)

    it("same version gate: error without any cleanup", function()
        local rels = { CTRL_REL }
        local UPD = begin_upd({ sys = { find_out(TMP, rels) } })
        seed_tree(TMP, rels, "4.1.0")
        assert.same({ error = "Archive version is not newer than installed" }, UPD.apply())
        for _, c in ipairs(H.exec_cmds()) do
            assert.falsy(c:find("rm -rf", 1, true))
        end
    end)

    it("happy strict copy: files land, counters right, caches cleared, uhttpd restarted", function()
        local rels = STRICT_FILES
        local UPD = begin_upd({ sys = { find_out(TMP, rels) } })
        seed_tree(TMP, rels, "4.2.5")
        local r = UPD.apply()
        assert.same({ success = true, new_version = "4.2.5", files_copied = #rels }, r)
        assert.equal(ctrl_content("4.2.5"), H.vfs_read("/usr/lib/lua/luci/controller/podkop-tweaker.lua"))
        assert.equal("data", H.vfs_read("/www/luci-static/resources/podkop-tweaker/common.js"))
        local saw_modulecache, saw_uhttpd = false, false
        for _, c in ipairs(H.exec_cmds()) do
            if c:find("luci-modulecache", 1, true) then saw_modulecache = true end
            if c:find("uhttpd restart", 1, true) then saw_uhttpd = true end
        end
        assert.truthy(saw_modulecache)
        assert.truthy(saw_uhttpd)
    end)

    it("files missing on disk are skipped by copier", function()
        local rels = { CTRL_REL, "usr/lib/lua/podkop-tweaker/ghost.lua" }
        local UPD = begin_upd({ sys = { find_out(TMP, rels) } })
        seed_tree(TMP, { CTRL_REL }, "4.2.0")
        local r = UPD.apply()
        assert.equal(1, r.files_copied)
    end)

    it("deprecated orphan file removed after successful apply", function()
        local ORPHAN = "/usr/lib/lua/luci/view/podkop-tweaker/podkop-tweaker-css.htm"
        local rels = { CTRL_REL }
        local UPD = begin_upd({ sys = { find_out(TMP, rels) } })
        seed_tree(TMP, rels, "4.2.0")
        H.vfs_write(ORPHAN, "stale css partial from 3.x")
        assert.truthy(UPD.apply().success)
        assert.falsy(H.vfs_exists(ORPHAN))
    end)
end)

describe("api_update.clear_cache", function()
    it("clears luci caches and check cache, restarts uhttpd", function()
        local UPD = begin_upd({})
        H.vfs_write(CACHE, "{}")
        assert.same({ success = true }, UPD.clear_cache())
        local saw_glob, saw_remove, saw_uhttpd = false, false, false
        for _, c in ipairs(H.execute_cmds()) do
            if c:find("rm -rf /tmp/luci-*", 1, true) then saw_glob = true end
            if c:find("remove " .. CACHE, 1, true) then saw_remove = true end
        end
        for _, c in ipairs(H.exec_cmds()) do
            if c:find("uhttpd restart", 1, true) then saw_uhttpd = true end
        end
        assert.truthy(saw_glob)
        assert.truthy(saw_remove)
        assert.truthy(saw_uhttpd)
    end)
end)

describe("api_update.read_log", function()
    it("empty when no log file", function()
        local UPD = begin_upd({})
        assert.same({ lines = {} }, UPD.read_log())
    end)

    it("returns lines in order", function()
        local UPD = begin_upd({})
        H.vfs_write(LOG, "first\nsecond\nthird\n")
        assert.same({ lines = { "first", "second", "third" } }, UPD.read_log())
        H.finish()
        local UPD2 = begin_upd({})
        H.vfs_write(LOG, "")
        assert.same({ lines = {} }, UPD2.read_log())
    end)
end)

describe("api_update.check_update", function()
    local function github_responder(out)
        return { match = "api.github.com", out = out }
    end

    it("fresh cache -> rate limited with retry_after", function()
        local UPD = begin_upd({})
        H.vfs_write(CACHE, '{"latest_version":"9","cached_at":' .. os.time() .. '}')
        local r = UPD.check_update()
        assert.equal("rate_limited", r.error)
        assert.truthy(r.retry_after > 895 and r.retry_after <= 900)
        assert.equal(0, #H.exec_cmds())
    end)

    it("stale cache falls through to network path", function()
        local UPD = begin_upd({ sys = { github_responder("") } })
        H.vfs_write(CACHE, '{"latest_version":"9","cached_at":' .. (os.time() - 2000) .. '}')
        assert.same({ error = "Failed to connect to GitHub" }, UPD.check_update())
    end)

    it("connection failure and parse failure", function()
        local UPD = begin_upd({ sys = { github_responder("") } })
        assert.same({ error = "Failed to connect to GitHub" }, UPD.check_update())
        H.finish()
        local UPD2 = begin_upd({ sys = { github_responder("<<<") } })
        assert.same({ error = "Failed to parse GitHub response" }, UPD2.check_update())
    end)

    it("github rate limit message surfaced", function()
        local UPD = begin_upd({ sys = { github_responder(GITHUB_RATE) } })
        assert.same({ error = "GitHub API rate limit exceeded" }, UPD.check_update())
    end)

    it("happy: fields, comparison and cache write-back", function()
        local UPD = begin_upd({ sys = { github_responder(GITHUB_OK) } })
        local r = UPD.check_update()
        assert.equal("4.1.0", r.current_version)
        assert.equal("4.9.9", r.latest_version)
        assert.is_true(r.update_available)
        assert.matches("/releases/download/v4%.9%.9/", r.download_url)
        local cached = require("luci.jsonc").parse(H.vfs_read(CACHE))
        assert.equal("4.9.9", cached.latest_version)
        assert.truthy(cached.cached_at)
    end)

    it("release without assets -> empty url; equal versions -> not available", function()
        local UPD = begin_upd({ sys = { github_responder('{"tag_name":"v4.1.0"}') } })
        local r = UPD.check_update()
        assert.equal("", r.download_url)
        assert.is_false(r.update_available)
    end)
end)

describe("api_update.git_update", function()
    local GOOD_URL = "https://github.com/InsaniaQuon/luci-app-podkop-tweaker/releases/download/v4.3.0/a.tar.gz"

    it("empty and foreign urls rejected", function()
        local UPD = begin_upd({})
        assert.same({ error = "Download URL is required" }, UPD.git_update("", nil))
        assert.same({ error = "Invalid download URL" }, UPD.git_update("https://evil.com/a.tar.gz", nil))
        assert.equal(0, #H.exec_cmds())
    end)

    it("download miss -> cleanup + error", function()
        local UPD = begin_upd({})
        assert.same({ error = "Failed to download archive" }, UPD.git_update(GOOD_URL, nil))
        assert.truthy(H.exec_cmds()[#H.exec_cmds()]:find("rm %-rf /tmp/pt%-git%-update"))
    end)

    it("oversize archive rejected", function()
        local UPD = begin_upd({})
        H.vfs_write(GTMP .. "/download.tar.gz", string.rep("x", 512001))
        assert.same({ error = "Archive too large" }, UPD.git_update(GOOD_URL, nil))
    end)

    it("traversal entry rejected before extraction even in relaxed mode (M1)", function()
        local rels = { CTRL_REL, "../evil" }
        local UPD = begin_upd({ sys = { tar_list_out(rels), find_out(GTMP, rels) } })
        seed_tree(GTMP, { CTRL_REL }, "4.3.0")
        H.vfs_write(GTMP .. "/download.tar.gz", "z")
        assert.same({ error = "Invalid archive" }, UPD.git_update(GOOD_URL, nil))
        for _, c in ipairs(H.exec_cmds()) do
            assert.falsy(c:find("tar -xzf", 1, true))
        end
    end)

    it("same version non-force gated with cleanup", function()
        local rels = { CTRL_REL }
        local UPD = begin_upd({ sys = { tar_list_out(rels), find_out(GTMP, rels) } })
        seed_tree(GTMP, rels, "4.1.0")
        H.vfs_write(GTMP .. "/download.tar.gz", "z")
        assert.same({ error = "Archive version is not newer than installed" },
            UPD.git_update(GOOD_URL, nil))
        local cleanups = 0
        for _, c in ipairs(H.exec_cmds()) do
            if c == "rm -rf /tmp/pt-git-update 2>/dev/null" then cleanups = cleanups + 1 end
        end
        -- initial rm -rf + gate-error cleanup
        assert.equal(2, cleanups)
    end)

    it("force bypasses gate: relaxed copy with chmod, cache invalidated", function()
        local rels = { CTRL_REL, "usr/bin/podkop-fragment-patch.sh" }
        local UPD = begin_upd({ sys = { tar_list_out(rels), find_out(GTMP, rels) } })
        seed_tree(GTMP, rels, "4.1.0")
        H.vfs_write(GTMP .. "/download.tar.gz", "z")
        H.vfs_write(CACHE, '{"latest_version":"4.1.0","cached_at":' .. os.time() .. '}')
        local r = UPD.git_update(GOOD_URL, "1")
        assert.same({ success = true, new_version = "4.1.0", files_copied = 2 }, r)
        assert.equal(ctrl_content("4.1.0"), H.vfs_read("/usr/lib/lua/luci/controller/podkop-tweaker.lua"))
        assert.equal("data", H.vfs_read("/usr/bin/podkop-fragment-patch.sh"))
        local chmodded = false
        for _, c in ipairs(H.execute_cmds()) do
            if c:find("chmod %+x '/usr/bin/podkop%-fragment%-patch%.sh'") then chmodded = true end
        end
        assert.truthy(chmodded)
        local cache_removed = false
        for _, c in ipairs(H.execute_cmds()) do
            if c:find("remove " .. CACHE, 1, true) then cache_removed = true end
        end
        assert.truthy(cache_removed)
    end)

    it("newer version applies without force", function()
        local rels = { CTRL_REL }
        local UPD = begin_upd({ sys = { tar_list_out(rels), find_out(GTMP, rels) } })
        seed_tree(GTMP, rels, "4.3.0")
        H.vfs_write(GTMP .. "/download.tar.gz", "z")
        local r = UPD.git_update(GOOD_URL, nil)
        assert.same({ success = true, new_version = "4.3.0", files_copied = 1 }, r)
    end)

    it("deprecated orphan removed after successful git_update; kept on version-gate failure", function()
        local ORPHAN = "/usr/lib/lua/luci/view/podkop-tweaker/podkop-tweaker-css.htm"
        local rels = { CTRL_REL }
        local UPD = begin_upd({ sys = { tar_list_out(rels), find_out(GTMP, rels) } })
        seed_tree(GTMP, rels, "4.3.0")
        H.vfs_write(GTMP .. "/download.tar.gz", "z")
        H.vfs_write(ORPHAN, "stale")
        assert.truthy(UPD.git_update(GOOD_URL, nil).success)
        assert.falsy(H.vfs_exists(ORPHAN))

        H.finish()
        local UPD2 = begin_upd({ sys = { tar_list_out(rels), find_out(GTMP, rels) } })
        seed_tree(GTMP, rels, "4.1.0")
        H.vfs_write(GTMP .. "/download.tar.gz", "z")
        H.vfs_write(ORPHAN, "stale")
        assert.same({ error = "Archive version is not newer than installed" },
            UPD2.git_update(GOOD_URL, nil))
        assert.truthy(H.vfs_exists(ORPHAN))
    end)
end)
