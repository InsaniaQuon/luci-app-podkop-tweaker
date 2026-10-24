-- Kernel-guarded resource lock regressions (4.11.0 stage A). All guard
-- files, owner metadata, epochs and /proc identities live in the harness VFS.
package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path
local H = require("pt_harness")
local GUARD = "/var/lock/podkop-tweaker-podkop.guard"
local OWNER = "/var/lock/podkop-tweaker-podkop.owner"
local DIR = "/var/lock/podkop-tweaker-podkop.lock"
local OTHER = "/var/lock/podkop-tweaker-subscriptions.lock"
local EPOCH = "/etc/podkop-tweaker.lock-epoch"

local function begin(opts)
    H.begin(opts)
    local SRV = require("podkop-tweaker.services")
    -- Recovery waits are instant unless a test observes them explicitly.
    SRV.lock_wait = function() end
    return SRV
end

local function enable_recovery(previous_boot)
    H.vfs_write("/proc/stat", "cpu 1 2 3\nbtime 5000\n")
    H.vfs_write(EPOCH, "pt-lock-epoch gen=1 btime=" .. tostring(previous_boot and 4999 or 5000) .. "\n")
end

after_each(function() H.finish() end)

describe("kernel-guarded resource locks", function()
    it("creates a stable guard file and owner metadata beside the resource directory", function()
        local S = begin()
        assert.equal("value", S.with_lock("podkop", function()
            assert.truthy(H.state().dirs[DIR])
            assert.truthy(H.vfs_exists(GUARD), "the guard inode must exist while held")
            assert.truthy(H.vfs_exists(OWNER), "owner metadata must be published before the callback")
            assert.matches("^pid=%d+ start=%d+ btime=%d+ token=", H.vfs_read(OWNER))
            return "value"
        end))
        assert.falsy(H.vfs_exists(DIR))
        assert.falsy(H.vfs_exists(OWNER), "release removes adjacent owner metadata")
        assert.truthy(H.vfs_exists(GUARD), "the guard inode is never unlinked or renamed")
    end)

    it("rejects a contender while a foreign process holds the guard", function()
        local S = begin()
        H.state().guard_state[GUARD] = { holder = 9999 }
        local entered = false
        local value, err = S.with_lock("podkop", function() entered = true end)
        assert.is_nil(value)
        assert.matches("busy or its lock is unavailable", err)
        assert.is_false(entered)
        assert.falsy(H.vfs_exists(DIR))
    end)

    it("refuses any lock activity in a forked copy of this Lua state", function()
        local S = begin()
        local refused = {}
        assert.equal("outer", S.with_lock("podkop", function()
            H.state().nixio_pid = 777
            for _, key in ipairs({ "podkop", "subscriptions" }) do
                local value, err = S.with_lock(key, function() return "wrong" end)
                refused[key] = value == nil and err ~= nil
            end
            H.state().nixio_pid = nil
            return "outer"
        end))
        assert.truthy(refused.podkop)
        assert.truthy(refused.subscriptions)
    end)

    it("refuses re-entry after an unfinished release instead of treating it as recursion", function()
        local S = begin({ failures = { [DIR] = { rmdir = true } } })
        local value, err, uncertain = S.with_lock("podkop", function() return { success = true } end)
        assert.is_nil(value)
        assert.is_true(uncertain)
        local second, second_err = S.with_lock("podkop", function() return "wrong" end)
        assert.is_nil(second)
        assert.matches("release did not complete", second_err)
        assert.truthy(H.vfs_exists(DIR))
    end)

    it("keeps singbox on the shared shell protocol without guard metadata", function()
        local S = begin()
        S.with_lock("singbox", function() return "ok" end)
        assert.falsy(H.vfs_exists("/var/lock/podkop-fragment.owner"))
        assert.falsy(H.vfs_exists("/var/lock/podkop-fragment.guard"))
    end)

    describe("stale resources without automatic recovery", function()
        it("never takes over an ownerless directory when no boot signature exists", function()
            local S = begin()
            H.vfs_mkdir(DIR)
            local value, err = S.with_lock("podkop", function() return "wrong" end)
            assert.is_nil(value)
            assert.matches("busy", err)
            assert.truthy(H.vfs_exists(DIR))
        end)

        it("pins the epoch on first use and keeps recovery disabled for this boot", function()
            local S = begin()
            H.vfs_write("/proc/stat", "btime 5000\n")
            H.vfs_mkdir(DIR, os.time() - 5000)
            local value = S.with_lock("podkop", function() return "wrong" end)
            assert.is_nil(value)
            assert.truthy(H.vfs_exists(DIR))
            assert.matches("^pt%-lock%-epoch gen=1 btime=5000", H.vfs_read(EPOCH))
        end)

        it("keeps recovery disabled while the epoch names the current boot", function()
            local S = begin()
            enable_recovery(false)
            H.vfs_mkdir(DIR, os.time() - 5000)
            assert.is_nil(S.with_lock("podkop", function() return "wrong" end))
            assert.truthy(H.vfs_exists(DIR))
        end)
    end)

    describe("ownerless takeover after the accepted 900-second policy", function()
        it("recovers a long-ownerless directory once a reboot separated generations", function()
            local S = begin()
            enable_recovery(true)
            H.vfs_mkdir(DIR, os.time() - 901)
            assert.equal("recovered", S.with_lock("podkop", function() return "recovered" end))
            assert.falsy(H.vfs_exists(DIR))
            assert.equal("again", S.with_lock("podkop", function() return "again" end))
        end)

        it("never touches a fresh ownerless directory", function()
            local S = begin()
            enable_recovery(true)
            H.vfs_mkdir(DIR, os.time() - 10)
            assert.is_nil(S.with_lock("podkop", function() return "wrong" end))
            assert.truthy(H.vfs_exists(DIR))
        end)

        it("refuses a non-empty ownerless directory for manual inspection", function()
            local S = begin()
            enable_recovery(true)
            H.vfs_mkdir(DIR, os.time() - 901)
            H.vfs_write(DIR .. "/leftover", "administrator evidence")
            assert.is_nil(S.with_lock("podkop", function() return "wrong" end))
            assert.truthy(H.vfs_exists(DIR))
            assert.equal("administrator evidence", H.vfs_read(DIR .. "/leftover"))
        end)
    end)

    describe("dead-owner takeover after the accepted grace policy", function()
        local function dead_owner(start)
            H.vfs_write(OWNER, string.format("pid=%d start=%d btime=5000 token=fixture-1\n", 999, start or 321))
        end

        it("waits outside the guard, re-verifies and recovers a verified-dead owner", function()
            local S = begin()
            enable_recovery(true)
            H.vfs_mkdir(DIR)
            dead_owner()
            local waits = 0
            SRV_WAIT = S.lock_wait
            S.lock_wait = function() waits = waits + 1 end
            assert.equal("recovered", S.with_lock("podkop", function() return "recovered" end))
            assert.equal(1, waits)
            assert.falsy(H.vfs_exists(DIR))
        end)

        it("keeps a live foreign owner busy", function()
            local S = begin()
            enable_recovery(true)
            H.vfs_mkdir(DIR)
            dead_owner()
            H.vfs_write("/proc/999/stat", "999 (lua) S " .. string.rep("0 ", 18) .. "321\n")
            assert.is_nil(S.with_lock("podkop", function() return "wrong" end))
            assert.truthy(H.vfs_exists(DIR))
            assert.truthy(H.vfs_exists(OWNER))
        end)

        it("does not act on a stale snapshot when the owner changes during the wait", function()
            local S = begin()
            enable_recovery(true)
            H.vfs_mkdir(DIR)
            dead_owner()
            S.lock_wait = function() dead_owner(654) end -- a different owner generation appeared
            H.vfs_write("/proc/999/stat", "999 (lua) S " .. string.rep("0 ", 18) .. "654\n")
            assert.is_nil(S.with_lock("podkop", function() return "wrong" end))
            assert.truthy(H.vfs_exists(DIR))
            assert.truthy(H.vfs_exists(OWNER))
        end)

        it("treats corrupt or unreadable owner metadata as busy, never as proof", function()
            local S = begin()
            enable_recovery(true)
            H.vfs_mkdir(DIR, os.time() - 5000)
            H.vfs_write(OWNER, "garbage without identity")
            assert.is_nil(S.with_lock("podkop", function() return "wrong" end))
            H.vfs_write(OWNER, "")
            assert.is_nil(S.with_lock("podkop", function() return "wrong" end))
            H.state().failures[OWNER] = { open = true }
            assert.is_nil(S.with_lock("podkop", function() return "wrong" end))
            assert.truthy(H.vfs_exists(DIR))
        end)
    end)
end)
