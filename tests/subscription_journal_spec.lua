package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path
local H = require("pt_harness")
local SUBS, LOG, CFG = "/etc/config/podkop-tweaker-subs.json", "/etc/config/pt-update.log", "/etc/config/podkop"
local SUB_LOCK, SERVICE_LOCK = "/var/lock/podkop-tweaker-subscriptions.lock", "/var/lock/podkop-tweaker-podkop.lock"
local TS = "12:00 19.10.2026"
local OLD, NEW = "vless://old@host:443#node", "vless://new@host:443#node"
local BASE = "config section 'main'\n option connection_type 'proxy'\n option proxy_config_type 'url'\n option proxy_string '" .. OLD .. "'\n"
local STATE = '{"main":[{"subscription_url":"https://provider.test/main","proxy_name":"node"}]}'
local original_date = os.date

local function begin(options)
    options = options or {}
    H.begin({ strict = true, failures = options.failures, uci = options.uci or { podkop = {
        H.sec("main", "section", { connection_type = "proxy", proxy_config_type = "url", proxy_string = OLD }) } },
        popen = {
            { match = "pidof 'sing-box'", out = "\nPT_EXIT:1\n" },
            { match = "/etc/init.d/podkop restart", out = function(command)
                if type(options.restart) == "function" then return options.restart(command) end
                return options.restart or "\nPT_EXIT:0\n"
            end },
            { match = "curl ", out = function(command)
                assert.falsy(H.vfs_exists(SUB_LOCK), "downloads must release the state lock")
                assert.falsy(H.vfs_exists(SERVICE_LOCK), "downloads must release the service lock")
                if options.fetch then return options.fetch(command) end
                return (options.payload or NEW) .. "\nPT_CURL_EXIT:0\n"
            end }
        } })
    os.date = function(format, time)
        if format == "%H:%M %d.%m.%Y" then return TS end
        return original_date(format, time)
    end
    H.vfs_write(CFG, options.config or BASE)
    H.vfs_write(SUBS, options.state or STATE)
    local s = require("pt-subs-lib")
    if not options.real_rng then
        local sequence = 0
        s.new_operation_id = function() sequence = sequence + 1; return string.format("%032x", sequence) end
    end
    return s
end

after_each(function() os.date = original_date; H.finish() end)

local function count(command)
    local n = 0
    for _, value in ipairs(H.popen_cmds()) do if value:find(command, 1, true) then n = n + 1 end end
    return n
end

local function events(s)
    local found = {}
    for line in (H.vfs_read(LOG) or ""):gmatch("[^\n]+") do
        local event = s.parse_log_header(line)
        if event then found[#found + 1] = event end
    end
    return found
end

local function update(s, mode) return s.update_all_subscriptions(SUBS, LOG, 25, mode or "manual") end
local function attach(s, link) return s.attach_subscription(SUBS, LOG, 25, "main", 0, "https://provider.test/main", "node", link or NEW) end
local function header(id, state, service, outcome)
    return TS .. "|auto|updated=1|unchanged=0|failed=0|id=" .. id .. "|state=" .. state .. "|service=" .. service ..
        "|skipped=0|outcome=" .. outcome
end

describe("subscription journal keyed schema", function()
    it("accepts the exact old header only as explicitly legacy", function()
        local s = begin()
        local old = TS .. "|auto|updated=2|unchanged=3|failed=4"
        assert.same({ ts = TS, mode = "auto", updated = 2, unchanged = 3, failed = 4, legacy = true }, s.parse_log_header(old))
        assert.is_nil(s.parse_log_header(old .. "|"))
        assert.is_nil(s.parse_log_header(old .. "|state=finished"))
    end)

    it("parses extensions by key rather than by position and accepts finished service-pending failures", function()
        local s = begin()
        local line = TS .. "|auto|updated=1|unchanged=0|failed=1|outcome=partial|service=pending|id=" .. string.rep("a", 32) .. "|skipped=2|state=finished"
        local event = assert(s.parse_log_header(line))
        assert.equal("finished", event.state)
        assert.equal("pending", event.service)
        assert.equal(2, event.skipped)
        assert.equal(1, event.failed)
        assert.is_nil(event.legacy)
    end)

    for _, suffix in ipairs({
        "id=" .. string.rep("a", 31) .. "|state=finished|service=requested|skipped=0|outcome=ok",
        "id=" .. string.rep("A", 32) .. "|state=finished|service=requested|skipped=0|outcome=ok",
        "id=" .. string.rep("a", 32) .. "|state=finished|service=success|skipped=0|outcome=ok",
        "id=" .. string.rep("a", 32) .. "|state=pending|service=requested|skipped=0|outcome=pending",
        "id=" .. string.rep("a", 32) .. "|state=finished|service=requested|skipped=0|outcome=pending",
        "id=" .. string.rep("a", 32) .. "|state=pending|service=pending|skipped=-1|outcome=pending",
        "id=" .. string.rep("a", 32) .. "|state=finished|service=requested|skipped=0|skipped=0",
        "id=" .. string.rep("a", 32) .. "|state=finished|service=requested|skipped=0|outcome=ok|extra=x"
    }) do
        it("rejects malformed extensions without legacy fallback: " .. suffix, function()
            local s = begin()
            assert.is_nil(s.parse_log_header(TS .. "|auto|updated=1|unchanged=0|failed=0|" .. suffix))
        end)
    end
end)

describe("subscription operation IDs", function()
    it("reads exactly 16 bytes, closes the source and returns lower-case hex before mutation", function()
        local s = begin({ real_rng = true })
        local bytes = "\0\1\2\3\4\5\6\7\8\9\10\11\12\13\254\255"
        H.vfs_write("/dev/urandom", bytes .. "unused")
        local open = io.open
        local reads, closes = 0, 0
        io.open = function(path, mode)
            local fd, err, errno = open(path, mode)
            if path == "/dev/urandom" and fd then
                local read, close = fd.read, fd.close
                fd.read = function(self, size) reads = reads + 1; assert.equal(16, size); assert.same({}, H.stage_paths()); return read(self, size) end
                fd.close = function(self) closes = closes + 1; return close(self) end
            end
            return fd, err, errno
        end
        local result = update(s)
        assert.equal("000102030405060708090a0b0c0dfeff", result.operation_id)
        assert.equal(1, reads)
        assert.equal(1, closes)
        assert.equal(1, #events(s))
    end)

    for _, operation in ipairs({ "missing", "open", "read", "short", "close", "read-and-close" }) do
        for _, flow in ipairs({ "all", "Attach" }) do
            it(flow .. " rejects RNG " .. operation .. " before data mutation or download", function()
                local s = begin({ real_rng = true })
                if operation ~= "missing" then H.vfs_write("/dev/urandom", string.rep("x", operation == "short" and 15 or 16)) end
                if operation ~= "short" and operation ~= "missing" then
                    H.state().failures["/dev/urandom"] = operation == "read-and-close" and { read = true, close = true } or { [operation] = true }
                end
                local result = flow == "all" and update(s) or attach(s)
                assert.is_false(result.success)
                assert.matches("operation ID", result.error)
                assert.is_string(result.error_details)
                assert.is_nil(result.operation_id)
                assert.equal(BASE, H.vfs_read(CFG))
                assert.equal(STATE, H.vfs_read(SUBS))
                assert.falsy(H.vfs_exists(LOG))
                assert.same({}, H.stage_paths())
                assert.equal(0, count("curl "))
                if operation == "read-and-close" then
                    assert.matches("Cannot read exactly", result.error_details)
                    assert.matches("Cannot close", result.error_details)
                end
            end)
        end
    end

    it("does not request an ID for invalid admission or unreadable initial state", function()
        local s = begin()
        s.new_operation_id = function() error("must not generate") end
        H.vfs_write(SUBS, "invalid")
        assert.is_string(update(s).error)
        assert.is_string(attach(s).error)
        assert.falsy(H.vfs_exists(LOG))
        assert.same({}, H.stage_paths())
    end)

    for _, operation in ipairs({ "read exception", "close exception", "bytes with read error" }) do
        it("rejects RNG " .. operation .. " and closes exactly once even when reading throws", function()
            local s = begin({ real_rng = true })
            H.vfs_write("/dev/urandom", string.rep("x", 16))
            local open, closes = io.open, 0
            io.open = function(path, mode)
                local fd, err, errno = open(path, mode)
                if path == "/dev/urandom" and fd then
                    local close = fd.close
                    fd.read = function()
                        if operation == "read exception" then error("RNG reader threw") end
                        return string.rep("x", 16), operation == "bytes with read error" and "RNG read error" or nil
                    end
                    fd.close = function(self)
                        closes = closes + 1
                        if operation == "close exception" then error("RNG closer threw") end
                        return close(self)
                    end
                end
                return fd, err, errno
            end
            local result = update(s)
            assert.is_false(result.success)
            assert.equal(1, closes)
            assert.is_string(result.error_details)
            assert.same({}, H.stage_paths())
            assert.equal(0, count("curl "))
        end)
    end
end)

describe("one durable subscription lifecycle", function()
    for _, flow in ipairs({ "manual", "auto", "Attach" }) do
        it(flow .. " writes pending before restart, then replaces the same ID exactly once", function()
            local s, pending
            s = begin({ restart = function()
                assert.falsy(H.vfs_exists(SUB_LOCK), "the outer subscriptions release must precede restart")
                assert.truthy(H.vfs_exists(SERVICE_LOCK))
                pending = events(s)
                assert.equal(1, #pending)
                assert.equal("pending", pending[1].state)
                return "\nPT_EXIT:0\n"
            end })
            local result = flow == "Attach" and attach(s) or update(s, flow)
            assert.equal("pending", result.service)
            assert.same({ recorded = true, finalized = false }, result.journal)
            assert.equal(0, count("/etc/init.d/podkop restart"))
            assert.is_string(H.json.stringify(result), "private completion context must not leak functions or cycles")
            s.finish_subscription_update(result)
            assert.is_true(result.success)
            assert.equal("requested", result.service)
            assert.equal("ok", result.outcome)
            assert.is_true(result.restart.command_result_known)
            assert.equal(0, result.restart.command_exit_code)
            assert.is_true(result.verification_required)
            assert.same({ recorded = true, finalized = true }, result.journal)
            local completed = events(s)
            assert.equal(1, #completed)
            assert.equal(pending[1].id, completed[1].id)
            assert.equal("finished", completed[1].state)
            assert.equal(0, completed[1].failed)
            local bytes, stages = H.vfs_read(LOG), #H.stage_paths(LOG .. ".tmp-write.*")
            s.finish_subscription_update(result)
            assert.equal(1, count("/etc/init.d/podkop restart"))
            assert.equal(bytes, H.vfs_read(LOG))
            assert.equal(stages, #H.stage_paths(LOG .. ".tmp-write.*"))
        end)
    end

    for _, release in ipairs({ false, true }) do
        for _, case in ipairs({ { service = "requested", output = "\nPT_EXIT:0\n", code = 0 },
            { service = "failed", output = "restart denied\nPT_EXIT:7\n", code = 7 },
            { service = "unknown", output = "lost marker" } }) do
            it("retains " .. case.service .. " command facts, release uncertainty=" .. tostring(release), function()
                local s = begin({ restart = function()
                    if release then H.state().failures[SERVICE_LOCK] = { rmdir = true } end
                    return case.output
                end })
                local result = update(s)
                s.finish_subscription_update(result)
                assert.equal(case.service, result.service)
                assert.equal(case.code, result.restart.command_exit_code)
                assert.equal(case.code ~= nil, result.restart.command_result_known)
                assert.equal(release or case.service == "unknown", result.unknown == true)
                assert.equal(0, result.failed)
                assert.equal(1, result.updated)
                assert.equal(case.service == "requested" and not release, result.success)
                assert.equal(result.success and "ok" or "partial", result.outcome)
                local event = events(s)[1]
                assert.equal("finished", event.state)
                assert.equal(case.service, event.service)
                assert.equal(0, event.failed, "service failures are not slot failures")
                assert.equal(result.outcome, event.outcome)
                assert.equal(1, count("/etc/init.d/podkop restart"))
            end)
        end
    end

    it("records failed restart-lock admission without invoking the service", function()
        local s = begin()
        local result = update(s)
        H.vfs_mkdir(SERVICE_LOCK)
        s.finish_subscription_update(result)
        assert.equal("failed", result.service)
        assert.equal(0, result.failed)
        assert.equal("finished", events(s)[1].state)
        assert.equal(0, count("/etc/init.d/podkop restart"))
    end)

    it("retains a journal event appended by a competing actor during the restart command", function()
        local s, concurrent
        concurrent = TS .. "|manual|updated=0|unchanged=3|failed=0\n  literal concurrent bytes\n"
        s = begin({ restart = function()
            local actor = coroutine.create(function() assert.is_true(s.append_log(LOG, 25, concurrent:sub(1, -2))) end)
            local ok, err = coroutine.resume(actor)
            assert.is_true(ok, tostring(err))
            assert.equal("dead", coroutine.status(actor))
            return "\nPT_EXIT:0\n"
        end })
        local result = update(s)
        s.finish_subscription_update(result)
        assert.is_true(result.success)
        assert.equal(2, #events(s))
        assert.is_true(events(s)[1].legacy)
        assert.equal(result.operation_id, events(s)[2].id)
        assert.truthy(H.vfs_read(LOG):find(concurrent, 1, true))
        assert.equal(1, count("/etc/init.d/podkop restart"))
    end)

    it("keeps processed slot download failures successful at the API while the event outcome is failed", function()
        local s = begin({ payload = "garbage" })
        local result = require("podkop-tweaker.api_subs").update_all()
        assert.is_true(result.success)
        assert.equal(1, result.failed)
        assert.equal("failed", result.outcome)
        assert.equal("not_required", result.service)
        assert.equal("failed", events(s)[1].outcome)
        assert.equal(3, count("curl "))
        assert.equal(0, count("/etc/init.d/podkop restart"))
    end)

    it("uses boolean unchanged for Attach and preserves shared slot details as API outcomes", function()
        local s = begin()
        local response = require("podkop-tweaker.api_subs").subscription_attach("main", "0", "https://provider.test/main", "node", OLD)
        assert.is_true(response.unchanged)
        assert.is_table(response.outcomes)
        assert.is_nil(response.details)
        assert.equal("not_required", response.service)
        assert.equal("finished", events(s)[1].state)
    end)

    for _, flow in ipairs({ "all", "Attach" }) do
        it(flow .. " records fatal disk-applied final-state failure once without restart", function()
            local s = begin({ failures = { [SUBS] = { rename = true } } })
            local result = flow == "all" and update(s) or attach(s)
            s.finish_subscription_update(result)
            assert.is_false(result.success)
            assert.is_true(result.applied)
            assert.is_true(result.restart_required)
            assert.equal(1, result.updated)
            assert.equal(1, result.failed, "the published slot also failed its association publication")
            assert.is_table(result.details)
            assert.equal(1, #events(s))
            assert.equal("finished", events(s)[1].state)
            assert.equal("pending", events(s)[1].service)
            assert.equal("partial", events(s)[1].outcome)
            assert.same({ recorded = true, finalized = true }, result.journal)
            assert.equal(0, count("/etc/init.d/podkop restart"))
        end)
    end

    it("attempts one finished event for an admitted fatal exception without fabricating applied bytes", function()
        local s = begin({ fetch = function() error("provider callback failed") end })
        local result = update(s)
        assert.is_false(result.success)
        assert.is_true(result.unknown)
        assert.falsy(result.applied)
        assert.equal(1, result.failed)
        assert.equal(0, result.updated)
        assert.matches("provider callback failed", result.error)
        assert.equal(1, #events(s))
        assert.equal("finished", events(s)[1].state)
        assert.equal("not_required", events(s)[1].service)
        assert.equal(1, count("curl "))
        assert.equal(0, count("/etc/init.d/podkop restart"))
    end)
end)

describe("subscription journal barriers and ownership", function()
    for _, failure in ipairs({ "read", "open", "close", "write", "rename", "oversize" }) do
        it("does not restart after initial journal " .. failure .. " failure or replay on a later finisher", function()
            local path = failure == "write" and LOG .. ".tmp-write.*" or LOG
            local s = begin({ failures = failure ~= "oversize" and { [path] = { [failure] = true, errno = 5 } } or {} })
            local before = failure == "oversize" and string.rep("x", s.LOG_MAX_SIZE + 1) or "previous\n"
            H.vfs_write(LOG, before)
            local result = update(s)
            assert.is_false(result.success)
            assert.is_true(result.applied)
            assert.is_true(result.restart_required)
            assert.equal(0, result.failed)
            assert.same(false, result.journal.recorded)
            assert.is_false(result.journal.finalized)
            H.state().failures[path] = nil
            s.finish_subscription_update(result)
            assert.equal(before, H.vfs_read(LOG))
            assert.equal(0, count("/etc/init.d/podkop restart"))
        end)
    end

    for _, published in ipairs({ false, true }) do
        it("requires outer pre-restart journal lock release; publication=" .. tostring(published), function()
            local s = begin()
            local append = s.append_log
            s.append_log = function(...)
                H.state().failures[SUB_LOCK] = { rmdir = true }
                if not published then H.state().failures[LOG] = { rename = true } end
                return append(...)
            end
            local result = update(s)
            assert.is_false(result.success)
            assert.equal(published, result.journal.recorded)
            assert.is_false(result.journal.finalized)
            assert.is_true(result.journal.unknown)
            assert.is_true(result.unknown)
            assert.equal(0, result.failed)
            s.finish_subscription_update(result)
            assert.equal(0, count("/etc/init.d/podkop restart"))
            assert.truthy(H.vfs_exists(SUB_LOCK), "never steal or clear the failed owned lock")
        end)
    end

    it("never lets serialized pending data or another coroutine acquire restart rights", function()
        local s = begin()
        local result = update(s)
        local reconstructed = H.json.parse(H.json.stringify(result))
        s.finish_subscription_update(reconstructed)
        local actor = coroutine.create(function() s.finish_subscription_update(result) end)
        assert.is_true(coroutine.resume(actor))
        assert.equal(0, count("/etc/init.d/podkop restart"))
        s.finish_subscription_update(result)
        assert.equal(1, count("/etc/init.d/podkop restart"))
    end)

    for _, conflict in ipairs({ "missing", "duplicate", "malformed duplicate", "counter", "slot detail" }) do
        it("reports " .. conflict .. " pending ID conflict without fallback append or restart replay", function()
            local s = begin({ restart = function()
                local pending = H.vfs_read(LOG)
                if conflict == "missing" then H.vfs_write(LOG, "concurrent bytes\n")
                elseif conflict == "duplicate" then H.vfs_write(LOG, pending .. pending)
                elseif conflict == "malformed duplicate" then H.vfs_write(LOG, pending .. pending:gsub("|state=pending", "|state=invalid"))
                elseif conflict == "counter" then H.vfs_write(LOG, pending:gsub("updated=1", "updated=8"))
                else H.vfs_write(LOG, pending:gsub("node: updated", "node: changed")) end
                return "\nPT_EXIT:0\n"
            end })
            local result = update(s)
            s.finish_subscription_update(result)
            assert.is_false(result.success)
            assert.equal("requested", result.service)
            assert.is_false(result.journal.finalized)
            assert.matches("Cannot finalize", result.journal.error)
            assert.is_string(result.journal.details)
            local bytes = H.vfs_read(LOG)
            s.finish_subscription_update(result)
            assert.equal(bytes, H.vfs_read(LOG))
            assert.equal(1, count("/etc/init.d/podkop restart"))
        end)
    end

    it("keeps the primary slot failure when journal publication and release also fail", function()
        local s = begin({ failures = { [SUBS] = { rename = true } } })
        local append = s.append_log
        s.append_log = function(...)
            H.state().failures[LOG] = { rename = true }
            H.state().failures[SUB_LOCK] = { rmdir = true }
            return append(...)
        end
        local result = update(s)
        assert.matches("Cannot save subscription state", result.error)
        assert.matches("Cannot write subscription update log", result.error_details)
        assert.matches("cannot release owned lock", result.error_details)
        assert.equal(1, result.updated)
        assert.equal(1, result.failed)
        assert.is_true(result.unknown)
        assert.is_false(result.journal.recorded)
    end)

    for _, final_written in ipairs({ false, true }) do
        it("retains restart evidence when final journal/release fails; final publication=" .. tostring(final_written), function()
            local s = begin({ restart = function()
                H.state().failures[SUB_LOCK] = { rmdir = true }
                if not final_written then H.state().failures[LOG] = { rename = true } end
                return "restart primary\nPT_EXIT:7\n"
            end })
            local result = update(s)
            s.finish_subscription_update(result)
            assert.equal("Service restart command failed", result.error)
            assert.matches("restart primary", result.error_details)
            assert.matches("Cannot finalize", result.error_details)
            assert.is_true(result.unknown)
            assert.is_true(result.journal.recorded)
            assert.equal(final_written, result.journal.finalized)
            assert.is_true(result.journal.unknown)
            assert.equal("failed", result.service)
            assert.equal(7, result.restart.command_exit_code)
            assert.equal(0, result.failed)
            assert.equal(1, count("/etc/init.d/podkop restart"))
            assert.equal(final_written and "finished" or "pending", events(s)[1].state)
        end)
    end
end)

describe("concurrent completion and pending-aware retention", function()
    it("completes same-minute coroutine actors in reverse order and preserves concurrent journal bytes", function()
        local other_old = "vless://old@other:443#node"
        local config = BASE .. "config section 'other'\n option proxy_string '" .. other_old .. "'\n"
        local s = begin({ config = config, uci = { podkop = {
            H.sec("main", "section", { connection_type = "proxy", proxy_config_type = "url", proxy_string = OLD }),
            H.sec("other", "section", { connection_type = "proxy", proxy_config_type = "url", proxy_string = other_old }) } } })
        local a, b
        local actor_a = coroutine.create(function() a = update(s, "auto"); coroutine.yield(); s.finish_subscription_update(a) end)
        assert.is_true(coroutine.resume(actor_a))
        H.vfs_write(SUBS, '{"other":[{"subscription_url":"https://provider.test/other","proxy_name":"node"}]}')
        local actor_b = coroutine.create(function() b = update(s, "auto"); coroutine.yield(); s.finish_subscription_update(b) end)
        assert.is_true(coroutine.resume(actor_b))
        assert.is_not.equal(a.operation_id, b.operation_id)
        assert.equal(2, #events(s))
        assert.is_true(coroutine.resume(actor_b))
        assert.is_true(b.success)
        local concurrent = TS .. "|manual|updated=0|unchanged=1|failed=0\n  retained bytes \r\n"
        assert.is_true(s.append_log(LOG, 25, concurrent:sub(1, -2)))
        assert.is_true(coroutine.resume(actor_a))
        assert.is_true(a.success)
        local completed = events(s)
        assert.equal(3, #completed)
        assert.equal(b.operation_id, completed[1].id)
        assert.is_true(completed[2].legacy)
        assert.equal(a.operation_id, completed[3].id)
        assert.equal(TS, completed[1].ts)
        assert.equal(TS, completed[3].ts)
        assert.truthy(H.vfs_read(LOG):find(concurrent, 1, true))
        assert.equal(2, count("/etc/init.d/podkop restart"))
    end)

    it("keeps every pending across legacy append/rotation, caps completed retention at 25 and finalizes after rotation", function()
        local s = begin()
        local result = update(s, "auto")
        for i = 1, 40 do
            assert.is_true(s.append_log(LOG, 100, TS .. "|manual|updated=0|unchanged=" .. i .. "|failed=0"))
        end
        assert.equal(26, #events(s))
        assert.equal(result.operation_id, events(s)[1].id)
        assert.is_true(s.rotate_log(LOG, 0))
        assert.equal(1, #events(s))
        assert.equal("pending", events(s)[1].state)
        s.finish_subscription_update(result)
        assert.is_true(result.success)
        assert.equal(1, #events(s))
        assert.equal("finished", events(s)[1].state)
    end)

    it("never silently drops pending data to satisfy the global cap", function()
        local s = begin()
        local pending = header(string.rep("a", 32), "pending", "pending", "pending") .. "\n  "
        pending = pending .. string.rep("x", s.LOG_MAX_SIZE - #pending - 1) .. "\n"
        H.vfs_write(LOG, pending)
        local ok, err = s.append_log(LOG, 25, header(string.rep("b", 32), "pending", "pending", "pending"))
        assert.is_false(ok)
        assert.matches("size limit", err)
        assert.equal(pending, H.vfs_read(LOG))
        assert.is_true(s.rotate_log(LOG, 0))
        assert.equal(pending, H.vfs_read(LOG))
    end)
end)

describe("bounded honest update-log read transport", function()
    it("returns empty only for positive first-use absence or a successful empty read", function()
        begin()
        local api = require("podkop-tweaker.api_update")
        assert.same({ lines = {} }, api.read_log())
        H.vfs_write(LOG, "")
        assert.same({ lines = {} }, api.read_log())
        H.vfs_write(LOG, "first\r\n\nlast")
        assert.same({ lines = { "first", "", "last" } }, api.read_log())
    end)
    for _, operation in ipairs({ "open", "read", "close", "oversize" }) do
        it("does not return empty-success or partial lines on " .. operation .. " failure", function()
            local s = begin({ failures = operation ~= "oversize" and { [LOG] = { [operation] = true, errno = 5 } } or {} })
            H.vfs_write(LOG, operation == "oversize" and string.rep("x", s.LOG_MAX_SIZE + 1) or "previous\n")
            local result = require("podkop-tweaker.api_update").read_log()
            assert.is_string(result.error)
            assert.is_string(result.details)
            assert.is_nil(result.lines)
            assert.same({}, H.stage_paths())
            assert.same({}, H.popen_cmds())
        end)
    end
end)
