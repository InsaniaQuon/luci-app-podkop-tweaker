-- pt_auto_update_spec | v1.0.0 | 23.08.2026 | Coverage for standalone pt-auto-update.lua (executes at require, cron/hotplug entry)

package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path

local H = require("pt_harness")

local SUBS = "/etc/config/podkop-tweaker-subs.json"
local LOG = "/etc/config/pt-update.log"
local CFG = "/etc/config/podkop"

local LINK_OLD = "vless://old@srv:443?security=tls#OldName"
local CFG_TEXT = "config section 'main'\n\toption connection_type 'proxy'\n\toption proxy_config_type 'url'\n\toption proxy_string '" .. LINK_OLD .. "'\n"
local UCI_MAIN = { podkop = { H.sec("main", "section", {
    connection_type = "proxy", proxy_config_type = "url", proxy_string = LINK_OLD }) } }
local SUB_ENTRY = '{"main":[{"subscription_url":"https://sub/1","proxy_name":"OldName"}]}'

local function run_auto(opts)
    H.begin(opts)
end

local function nohup_count()
    local n = 0
    for _, c in ipairs(H.execute_cmds()) do
        if c:find("^nohup /etc/init%.d/podkop restart") then n = n + 1 end
    end
    return n
end

after_each(function()
    H.finish()
end)

describe("pt-auto-update", function()
    it("updated subscription: rewrites config, restarts podkop, logs auto mode", function()
        run_auto({
            uci = UCI_MAIN,
            popen = function(cmd)
                if cmd:find("^mktemp") then return "/tmp/pt-fixed\n" end
                return ""
            end
        })
        H.vfs_write(CFG, CFG_TEXT)
        H.vfs_write(SUBS, SUB_ENTRY)
        H.vfs_write("/tmp/pt-fixed", "vless://fresh@f:443#OldName\n")
        -- script already ran at require with empty world; rerun with seeded state
        package.loaded["pt-auto-update"] = nil
        require("pt-auto-update")

        assert.truthy(H.vfs_read(CFG):find("vless://fresh@f:443#OldName", 1, true))
        assert.equal(1, nohup_count())
        local log = H.vfs_read(LOG)
        assert.truthy(log:find("|auto|", 1, true))
        assert.truthy(log:find("updated=1", 1, true))
        assert.truthy(log:find("OldName: updated", 1, true))
    end)

    it("unchanged subscription: no restart", function()
        run_auto({
            uci = UCI_MAIN,
            popen = function(cmd)
                if cmd:find("^mktemp") then return "/tmp/pt-fixed\n" end
                return ""
            end
        })
        H.vfs_write(CFG, CFG_TEXT)
        H.vfs_write(SUBS, SUB_ENTRY)
        H.vfs_write("/tmp/pt-fixed", LINK_OLD .. "\n")
        package.loaded["pt-auto-update"] = nil
        require("pt-auto-update")

        assert.equal(CFG_TEXT, H.vfs_read(CFG))
        assert.equal(0, nohup_count())
        assert.truthy(H.vfs_read(LOG):find("unchanged=1", 1, true))
    end)

    it("failed download: retries logged, no restart", function()
        run_auto({
            uci = UCI_MAIN,
            popen = function(cmd)
                if cmd:find("^mktemp") then return "/tmp/pt-fixed\n" end
                return ""
            end
        })
        H.vfs_write(CFG, CFG_TEXT)
        H.vfs_write(SUBS, SUB_ENTRY)
        H.vfs_write("/tmp/pt-fixed", "garbage\n")
        package.loaded["pt-auto-update"] = nil
        require("pt-auto-update")

        assert.equal(CFG_TEXT, H.vfs_read(CFG))
        assert.equal(0, nohup_count())
        local log = H.vfs_read(LOG)
        assert.truthy(log:find("failed=1", 1, true))
        local sleeps = 0
        for _, c in ipairs(H.execute_cmds()) do
            if c:find("^sleep 10") then sleeps = sleeps + 1 end
        end
        assert.equal(2, sleeps)
    end)

    it("empty world: zero counters, log still written, no side effects", function()
        run_auto({})
        require("pt-auto-update")
        assert.equal(0, nohup_count())
        assert.equal(0, #H.exec_cmds())
        local log = H.vfs_read(LOG)
        assert.truthy(log)
        assert.truthy(log:find("updated=0|unchanged=0|failed=0", 1, true))
    end)
end)
