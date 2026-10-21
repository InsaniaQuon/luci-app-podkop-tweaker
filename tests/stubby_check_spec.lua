-- Stubby ST1: actual UID/socket facts, independent failures and literal-only init changes.
package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path
local H = require("pt_harness")
local INIT = "/etc/init.d/stubby"
local SCRIPT = "#!/bin/sh /etc/rc.common\nstart_service() {\n    procd_set_param user \"stubby\" # keep this comment\n}\n"
local CONFIG = "config stubby 'global'\n option manual '0'\n list listen_address '127.0.0.53@53'\n"
local HEADER = "Active Internet connections (only servers)\nProto Recv-Q Send-Q Local Address Foreign Address State PID/Program name\n"
local SOCKETS = HEADER .. "tcp 0 0 127.0.0.53:53 0.0.0.0:* LISTEN 123/stubby\nudp 0 0 127.0.0.53:53 0.0.0.0:* 123/stubby\n"

local function stat(pid, start)
    return pid .. " (stubby) S " .. string.rep("0 ", 18) .. (start or "200") .. "\n"
end
local function process(pid, uid)
    H.vfs_write("/proc/" .. pid .. "/stat", stat(pid))
    H.vfs_write("/proc/" .. pid .. "/status", "Name:\tstubby\nState:\tS (sleeping)\nUid:\t" .. uid .. "\t" .. uid .. "\t" .. uid .. "\t" .. uid .. "\n")
end
local function begin(opts)
    opts = opts or {}
    H.begin({ strict = true, failures = opts.failures, popen = {
        { match = "pidof 'stubby'", out = opts.pid or "123\nPT_EXIT:0\n" },
        { match = "netstat -lntup", out = opts.sockets or SOCKETS .. "\nPT_STUBBY_NETSTAT:0\n\nPT_EXIT:0\n" }
    } })
    H.vfs_write(INIT, opts.init or SCRIPT)
    H.vfs_write("/etc/config/stubby", opts.config or CONFIG)
    process("123", opts.uid or "0")
    return require("podkop-tweaker.stubby_check")
end

after_each(function() H.finish() end)

describe("ST1 observed init/runtime/listener facts", function()
    it("proves root using live UID while reporting the different init declaration separately", function()
        local r = begin().read()
        assert.equal(2, r.check_version)
        assert.equal("fixed", r.status)
        assert.same({ state = "literal", user = "stubby" }, r.init)
        assert.equal("root", r.runtime.state)
        assert.same({ { pid = "123", euid = 0, instance = "123:200" } }, r.runtime.processes)
        assert.equal("observed", r.listeners.state)
        assert.equal(2, r.listeners.count)
        assert.same({ state = "uci", listen_count = 1, listen_addresses = { "127.0.0.53@53" } }, r.config)
        for _, call in ipairs(H.state().io_log) do assert.falsy(call.operation == "write" or call.operation == "rename" or call.operation == "remove") end
        for _, cmd in ipairs(H.popen_cmds()) do assert.falsy(cmd:find(" restart", 1, true)) end
    end)

    for _, port in ipairs({ "53", "5353" }) do
        it("does not flag a working non-root process on port " .. port .. " as needing root", function()
            local r = begin({ uid = "453", sockets = SOCKETS:gsub(":53", ":" .. port) .. "\nPT_STUBBY_NETSTAT:0\n\nPT_EXIT:0\n" }).read()
            assert.equal("user", r.runtime.state)
            assert.equal(453, r.runtime.processes[1].euid)
            assert.equal("observed", r.listeners.state)
            assert.equal("unknown", r.status, "legacy callers must not infer root from a source substring")
            assert.not_equal("needs_fix", r.status)
            assert.matches("Optional", r.repair.reason)
        end)
    end

    it("reports stopped rather than root for a root init declaration without a process", function()
        local r = begin({ init = SCRIPT:gsub('"stubby"', '"root"'), pid = "\nPT_EXIT:1\n" }).read()
        assert.equal("root", r.init.user)
        assert.equal("stopped", r.runtime.state)
        assert.equal("unknown", r.status)
        assert.equal("none", r.listeners.state)
        assert.is_false(r.repair.available)
    end)

    it("distinguishes PID query failure from known absence", function()
        local r = begin({ pid = "query failed\nPT_EXIT:2\n" }).read()
        assert.equal("unknown", r.runtime.state)
        assert.matches("query failed", r.runtime.error)
        assert.equal("unknown", r.listeners.state)
    end)

    for _, failure in ipairs({ "open", "read", "close" }) do
        it("does not invent root after a process-status " .. failure .. " failure", function()
            local r = begin({ failures = { ["/proc/123/status"] = { [failure] = true } } }).read()
            assert.equal("unknown", r.runtime.state)
            assert.equal("unknown", r.status)
            assert.equal("literal", r.init.state)
            assert.equal("uci", r.config.state)
        end)
    end

    it("keeps runtime and sockets independent of an unreadable init/config", function()
        local r = begin({ failures = { [INIT] = { read = true }, ["/etc/config/stubby"] = { close = true } } }).read()
        assert.equal("unknown", r.init.state)
        assert.equal("unknown", r.config.state)
        assert.equal("root", r.runtime.state)
        assert.equal("observed", r.listeners.state)
        assert.is_false(r.repair.available)
    end)

    it("does not infer manual YAML listeners from unused UCI values", function()
        local r = begin({ config = CONFIG:gsub("manual '0'", "manual '1'") }).read()
        assert.equal("manual", r.config.state)
        assert.equal("observed", r.listeners.state)
    end)

    it("handles mixed process UIDs without reporting all instances as root", function()
        local C = begin({ pid = "123 456\nPT_EXIT:0\n" })
        process("456", "453")
        local r = C.read()
        assert.equal("mixed", r.runtime.state)
        assert.equal(2, r.runtime.process_count)
        assert.equal("unknown", r.status)
    end)

    for _, raw in ipairs({ "", "permission denied\n\nPT_STUBBY_NETSTAT:1\n\nPT_EXIT:0\n", "PT_STUBBY_NETSTAT_OVERFLOW\n\nPT_EXIT:0\n",
        "not a table\nPT_STUBBY_NETSTAT:0\n\nPT_EXIT:0\n", HEADER .. "udp 0 0 127.0.0.53:53 0.0.0.0:* -\n\nPT_STUBBY_NETSTAT:0\n\nPT_EXIT:0\n" }) do
        it("does not turn missing/failed/malformed/ownerless socket evidence into absence", function()
            local r = begin({ sockets = raw }).read()
            assert.equal("root", r.runtime.state)
            assert.equal("unknown", r.listeners.state)
            assert.truthy(r.listeners.error)
        end)
    end

    it("does not attribute another service's port to Stubby", function()
        local r = begin({ sockets = SOCKETS:gsub("123/stubby", "456/dnsmasq") .. "\nPT_STUBBY_NETSTAT:0\n\nPT_EXIT:0\n" }).read()
        assert.equal("none", r.listeners.state)
        assert.equal(0, r.listeners.count)
    end)

    it("reads IPv6 owner rows without confusing colons with the port", function()
        local r = begin({ sockets = SOCKETS:gsub("127.0.0.53", "::1") .. "\nPT_STUBBY_NETSTAT:0\n\nPT_EXIT:0\n" }).read()
        assert.equal("observed", r.listeners.state)
        assert.equal("::1", r.listeners.entries[1].address)
        assert.equal(53, r.listeners.entries[1].port)
    end)

    it("invalidates UID and socket facts if the process changes during socket enumeration", function()
        local C = begin({ sockets = function()
            H.vfs_write("/proc/123/stat", stat("123", "201"))
            return SOCKETS .. "\nPT_STUBBY_NETSTAT:0\n\nPT_EXIT:0\n"
        end })
        local r = C.read()
        assert.equal("unknown", r.runtime.state)
        assert.equal("unknown", r.listeners.state)
    end)
end)

describe("ST1 literal init candidate", function()
    for _, declaration in ipairs({ "procd_set_param user stubby", "procd_set_param\tuser\t'stubby'", 'procd_set_param user "stubby" ; # retain' }) do
        it("changes only the supported literal value in " .. declaration, function()
            local C = begin()
            local source = "#!/bin/sh\n# procd_set_param user stubby\nstart_service() { # comment\n " .. declaration .. "\n}\n"
            local fixed, err = C.root_candidate(source)
            assert.truthy(fixed, err)
            assert.matches("# procd_set_param user stubby", fixed)
            assert.equal(1, select(2, fixed:gsub("root", "root")))
            assert.equal(source:sub(1, source:find("start_service", 1, true) - 1), fixed:sub(1, fixed:find("start_service", 1, true) - 1))
        end)
    end

    for _, source in ipairs({
        "# procd_set_param user stubby\n", "echo 'procd_set_param user stubby'\n",
        "start_service() {\n procd_set_param user \"$USER\"\n}\n",
        "start_service() {\n procd_set_param user stubby\n procd_set_param user root\n}\n",
        "start_service() {\n false && procd_set_param user stubby\n}\n",
        "start_service() {\n procd_set_param user stubby; echo extra\n}\n",
        "cat <<'EOF'\nstart_service() {\n procd_set_param user stubby\n}\nEOF\n",
        "echo 'payload\nprocd_set_param user stubby\n'\n",
        "# binary\0payload\nstart_service() {\n procd_set_param user stubby\n}\n",
        "start_service() {\r\n procd_set_param user stubby\r\n}\r\n",
        "other() {\n procd_set_param user stubby\n}\n",
        "start_service() {\n procd_set_param user stubby\n}\nstart_service() {\n :\n}\n",
        "start_service() {\n procd_set_param user custom\n}\n"
    }) do
        it("refuses ambiguous/comment/payload/dynamic/custom changes", function()
            local fixed, err = begin().root_candidate(source)
            assert.is_nil(fixed)
            assert.truthy(err)
        end)
    end

    it("retains the final newline state and explicit root no-op", function()
        local C = begin()
        local source = SCRIPT:sub(1, -2)
        local fixed = assert(C.root_candidate(source))
        assert.equal("}", fixed:sub(-1))
        local same, err, unchanged = C.root_candidate(fixed)
        assert.equal(fixed, same)
        assert.is_nil(err)
        assert.is_true(unchanged)
    end)

    it("accepts the upstream nested inline substitutions without executing init", function()
        local C = begin()
        local source = '#!/bin/sh /etc/rc.common\nstart_service() {\n' ..
            ' if [ "$("$stubby_init" enabled; printf "%u" $?)" -eq 0 ]; then\n' ..
            '  procd_open_instance "stubby"\n  procd_set_param command "$stubby" -C "$stubby_config"\n' ..
            '  procd_set_param user stubby\n  procd_close_instance\n fi\n}\n'
        local result, err = C.root_candidate(source)
        assert.truthy(result, err)
        assert.equal(source:gsub('procd_set_param user stubby', 'procd_set_param user root'), result)
        assert.equal(0, #H.popen_cmds())
    end)
end)

describe("ST1 native bounded socket collector", function()
    it("preserves the native tool exit and caps output while draining the producer", function()
        local C = require("podkop-tweaker.stubby_check")
        local SRV = require("podkop-tweaker.services")
        local ok, output = SRV.exec_checked("netstat() { printf 'native failure\\n'; return 17; }; " .. C.LISTENER_COMMAND)
        assert.is_true(ok)
        assert.matches("native failure", output)
        assert.matches("PT_STUBBY_NETSTAT:17\n$", output)
        ok, output = SRV.exec_checked("netstat() { i=0; while [ \"$i\" -lt 10000 ]; do printf 'bounded native socket table row\\n'; i=$((i+1)); done; }; " .. C.LISTENER_COMMAND)
        assert.is_true(ok)
        assert.truthy(output:find("PT_STUBBY_NETSTAT_OVERFLOW", 1, true))
        assert.is_true(#output < 65600)
    end)
end)
