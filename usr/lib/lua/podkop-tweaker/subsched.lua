-- Podkop Tweaker | subscription auto-update scheduling (cron + hotplug)
-- Author: InsaniaQuon

local M = {}

local sys = require("luci.sys")
local SRV = require("podkop-tweaker.services")
local LIB = require("podkop-tweaker.lib")
local S = require("pt-subs-lib")
local CRONTAB = "/etc/crontabs/root"
local CRON_INPUT = "/tmp/pt-subscriptions.cron"
local LAUNCHER = "/usr/bin/pt-auto-update"
local HOTPLUG = "/etc/hotplug.d/iface/99-pt-subs"
local SCRIPT = "#!/bin/sh\nlua /usr/lib/lua/pt-auto-update.lua\n"
local HOOK = '#!/bin/sh\n[ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "wan" ] && (sleep 30; /usr/bin/pt-auto-update) >/dev/null 2>&1 &\n'
local READ_LIMIT = 65536

function M.cron_line(interval, start_time)
    interval = tonumber(interval)
    if not interval or interval <= 0 then return nil end
    if interval ~= math.floor(interval) or interval > 24 then return nil end
    local hh, mm = tostring(start_time or ""):match("^(%d%d):(%d%d)$")
    if not hh or not mm then return nil end
    hh, mm = tonumber(hh), tonumber(mm)
    if hh > 23 or mm > 59 then return nil end
    local hours = {}
    local h = hh
    while h <= 23 do
        table.insert(hours, tostring(h))
        h = h + interval
    end
    return mm .. " " .. table.concat(hours, ",") .. " * * * " .. LAUNCHER
end

local function read_optional(path)
    local fd, err, errno = io.open(path, "rb")
    if not fd then
        if errno == 2 then return "", nil, false end
        return nil, err or "Cannot read " .. path
    end
    local data, read_err = SRV.read_stream(fd, READ_LIMIT)
    local closed, close_err = fd:close()
    if not data then return nil, read_err end
    if not closed then return nil, "Cannot close " .. path .. ": " .. tostring(close_err or "Unknown close failure") end
    return data, nil, true
end

local function pack(...) return { n = select("#", ...), ... } end

local function with_subscriptions(fn)
    local completed
    local result = pack(SRV.with_lock("subscriptions", function()
        completed = pack(fn())
        return unpack(completed, 1, completed.n)
    end))
    if result[1] ~= nil then return unpack(result, 1, result.n) end
    -- The lock's third result means uncertainty; the callback's third result
    -- records an actual publication/installation. Keep those facts separate.
    completed = completed or { n = 0 }
    local primary, lock_err = completed[2], tostring(result[2] or "Cannot coordinate subscription scheduling")
    completed[1] = false
    completed[2] = primary and (primary .. "\n" .. lock_err) or lock_err
    completed[3] = completed[3] == true
    completed[4] = completed[4] == true or result[3] == true
    completed.n = math.max(completed.n, 4)
    return unpack(completed, 1, completed.n)
end

local function own_cron_job(line)
    if line:match("^%s*#") then return false end
    local command = line:match("^%s*%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+(.-)%s*$")
    return command == LAUNCHER
end

local function setup_cron(interval, start_time)
    local expected = M.cron_line(interval, start_time)
    if tonumber(interval) and tonumber(interval) > 0 and not expected then return false, "Invalid schedule" end
    local current, err = read_optional(CRONTAB)
    if not current then return false, err end
    local lines, offset = {}, 1
    while offset <= #current do
        local newline = current:find("\n", offset, true)
        local last = newline or #current
        local line = current:sub(offset, newline and newline - 1 or last)
        if not own_cron_job(line) then lines[#lines + 1] = current:sub(offset, last) end
        offset = last + 1
    end
    local content = table.concat(lines)
    if expected then
        if content ~= "" and content:sub(-1) ~= "\n" then content = content .. "\n" end
        content = content .. expected .. "\n"
    end
    if content == current then return true end
    -- This input is never published at CRON_INPUT. Only the exclusively allocated
    -- private stage is passed to crontab and cleaned by its registered owner.
    local stage, stage_err = SRV.stage_file(CRON_INPUT, content, { mode = "600" })
    if not stage then return false, stage_err end
    -- crontab installs with the correct owner/mode and notifies BusyBox crond.
    local installed, details, exit_code = SRV.exec_checked("crontab " .. LIB.shell_escape(stage))
    local cleaned, cleanup_err = SRV.discard_stage(stage)
    if not installed or not cleaned then
        local errors = {}
        if not installed then errors[#errors + 1] = "Cannot install crontab: " .. tostring(details or "Missing command result") end
        if not cleaned then errors[#errors + 1] = "Cannot remove private crontab input: " .. tostring(cleanup_err or "Unknown cleanup failure") end
        return false, table.concat(errors, "\n"), installed == true, exit_code == nil
    end
    return true, nil, true
end

function M.setup_cron(interval, start_time)
    return with_subscriptions(function() return setup_cron(interval, start_time) end)
end

local function setup_hotplug(enabled)
    if enabled then
        local made, details = SRV.exec_checked("mkdir -p /etc/hotplug.d/iface")
        if not made then return false, "Cannot create hotplug directory: " .. tostring(details or "Missing command result") end
        local written, err = SRV.write_file_atomic(HOTPLUG, HOOK, { executable = true })
        return written, err, written == true
    end
    local content, err, present = read_optional(HOTPLUG)
    if not content then return false, err end
    if not present then return true end
    local removed, remove_err = os.remove(HOTPLUG)
    if not removed then return false, remove_err or "Cannot remove hotplug hook" end
    return true, nil, true
end

function M.setup_hotplug(enabled)
    return with_subscriptions(function() return setup_hotplug(enabled) end)
end

function M.create_auto_update_script()
    return with_subscriptions(function()
        local written, err = SRV.write_file_atomic(LAUNCHER, SCRIPT, { executable = true })
        return written, err, written == true
    end)
end

local function apply(interval, start_time, on_restart)
    local launcher_written = false
    if (tonumber(interval) or 0) > 0 or on_restart then
        local ok, err, applied, unknown = M.create_auto_update_script()
        if not ok then return false, err, applied, unknown end
        launcher_written = true
    end
    local cron_ok, cron_err, cron_applied, cron_unknown = M.setup_cron(interval, start_time)
    local hook_ok, hook_err, hook_applied, hook_unknown = M.setup_hotplug(on_restart)
    local applied = launcher_written or cron_applied == true or hook_applied == true
    local unknown = cron_unknown == true or hook_unknown == true
    if not cron_ok or not hook_ok then
        local errors = {}
        if not cron_ok then errors[#errors + 1] = cron_err end
        if not hook_ok then errors[#errors + 1] = hook_err end
        return false, table.concat(errors, "\n"), applied, unknown
    end
    return true, nil, applied, unknown
end

function M.apply(interval, start_time, on_restart)
    return with_subscriptions(function() return apply(interval, start_time, on_restart) end)
end

local function script_status(path, expected)
    local content, err, present = read_optional(path)
    local exists = present == true
    return { exists = exists, matches = exists and content == expected,
        executable = exists and LIB.exit_ok(os.execute("test -x " .. LIB.shell_escape(path))), error = err }
end

local function last_auto(log_file)
    local fd = io.open(log_file, "rb")
    if not fd then return nil end
    local size = fd:seek("end")
    local offset = size and math.max(0, size - READ_LIMIT)
    if not offset or not fd:seek("set", offset) then fd:close(); return nil end
    local text = SRV.read_stream(fd, READ_LIMIT)
    local closed = fd:close()
    if not text or not closed then return nil end
    if offset > 0 then text = text:match("\n(.*)$") or "" end
    local last, pending
    for line in text:gmatch("[^\r\n]+") do
        local event = S.parse_log_header(line)
        if event and event.mode == "auto" then
            event.mode = nil
            if event.state == "pending" then pending = event
            else
                -- File order is completion order; timestamps may share a minute.
                last, pending = event, nil
            end
        end
    end
    return last, pending
end

function M.status(settings, log_file)
    settings = type(settings) == "table" and settings or {}
    local expected = M.cron_line(settings.auto_update_interval, settings.auto_update_start)
    local enabled = (tonumber(settings.auto_update_interval) or 0) > 0
    local cron, cron_err = read_optional(CRONTAB)
    local actual = {}
    for line in (cron or ""):gmatch("[^\r\n]+") do
        if own_cron_job(line) then
            actual[#actual + 1] = line:match("^%s*(.-)%s*$")
        end
    end
    local hook = script_status(HOTPLUG, HOOK)
    hook.enabled = settings.auto_update_on_restart == true
    local completed, pending = last_auto(log_file)
    return {
        cron = { enabled = enabled, expected = expected,
            matches = not cron_err and ((enabled and expected and #actual == 1 and actual[1] == expected) or (not enabled and #actual == 0)) or false,
            running = (sys.exec("pidof crond 2>/dev/null") or ""):match("%d+") ~= nil,
            actual = actual, error = cron_err },
        launcher = script_status(LAUNCHER, SCRIPT), hotplug = hook,
        last_auto = completed, last_auto_pending = pending, log_window_bytes = READ_LIMIT
    }
end

return M
