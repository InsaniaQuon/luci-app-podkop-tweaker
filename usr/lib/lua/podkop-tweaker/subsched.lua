-- Podkop Tweaker | subscription auto-update scheduling (cron + hotplug)
-- Author: InsaniaQuon

local M = {}

local sys = require("luci.sys")
local SRV = require("podkop-tweaker.services")
local LIB = require("podkop-tweaker.lib")
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
    local closed = fd:close()
    if not data or not closed then return nil, read_err or "Cannot close " .. path end
    return data, nil, true
end

function M.setup_cron(interval, start_time)
    local expected = M.cron_line(interval, start_time)
    if tonumber(interval) and tonumber(interval) > 0 and not expected then return false, "Invalid schedule" end
    local current, err = read_optional(CRONTAB)
    if not current then return false, err end
    local lines = {}
    for line in current:gmatch("[^\r\n]+") do
        if not line:find(LAUNCHER, 1, true) then lines[#lines + 1] = line end
    end
    if expected then lines[#lines + 1] = expected end
    local content = #lines > 0 and table.concat(lines, "\n") .. "\n" or ""
    if content == current then return true end
    local ok, write_err = SRV.write_file_atomic(CRON_INPUT, content, { mode = "600" })
    if not ok then return false, write_err end
    -- crontab installs with the correct owner/mode and notifies BusyBox crond.
    local raw = sys.exec("crontab " .. LIB.shell_escape(CRON_INPUT) .. " 2>&1; printf '\\nPT_EXIT:%s\\n' \"$?\"") or ""
    os.remove(CRON_INPUT)
    local details, status = raw:match("^(.*)\nPT_EXIT:(%d+)\n$")
    if status ~= "0" then return false, "Cannot install crontab: " .. (details or raw) end
    return true
end

function M.setup_hotplug(enabled)
    if enabled then
        if not LIB.exit_ok(os.execute("mkdir -p /etc/hotplug.d/iface 2>/dev/null")) then
            return false, "Cannot create hotplug directory"
        end
        return SRV.write_file_atomic(HOTPLUG, HOOK, { executable = true })
    end
    local content, err = read_optional(HOTPLUG)
    if not content then return false, err end
    if content == "" then
        local fd = io.open(HOTPLUG, "rb")
        if not fd then return true end
        fd:close()
    end
    local removed, remove_err = os.remove(HOTPLUG)
    if not removed then return false, remove_err or "Cannot remove hotplug hook" end
    return true
end

function M.create_auto_update_script()
    return SRV.write_file_atomic(LAUNCHER, SCRIPT, { executable = true })
end

function M.apply(interval, start_time, on_restart)
    if (tonumber(interval) or 0) > 0 or on_restart then
        local ok, err = M.create_auto_update_script()
        if not ok then return false, err end
    end
    local cron_ok, cron_err = M.setup_cron(interval, start_time)
    local hook_ok, hook_err = M.setup_hotplug(on_restart)
    if not cron_ok or not hook_ok then
        local errors = {}
        if not cron_ok then errors[#errors + 1] = cron_err end
        if not hook_ok then errors[#errors + 1] = hook_err end
        return false, table.concat(errors, "\n")
    end
    return true
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
    local last
    for line in text:gmatch("[^\r\n]+") do
        local ts, updated, unchanged, failed = line:match("^(%d%d:%d%d %d%d%.%d%d%.%d%d%d%d)|auto|updated=(%d+)|unchanged=(%d+)|failed=(%d+)$")
        if ts and #updated <= 10 and #unchanged <= 10 and #failed <= 10 then
            last = { ts = ts, updated = tonumber(updated), unchanged = tonumber(unchanged), failed = tonumber(failed) }
        end
    end
    return last
end

function M.status(settings, log_file)
    settings = type(settings) == "table" and settings or {}
    local expected = M.cron_line(settings.auto_update_interval, settings.auto_update_start)
    local enabled = (tonumber(settings.auto_update_interval) or 0) > 0
    local cron, cron_err = read_optional(CRONTAB)
    local actual = {}
    for line in (cron or ""):gmatch("[^\r\n]+") do
        if not line:match("^%s*#") and line:find(LAUNCHER, 1, true) then
            actual[#actual + 1] = line:match("^%s*(.-)%s*$")
        end
    end
    local hook = script_status(HOTPLUG, HOOK)
    hook.enabled = settings.auto_update_on_restart == true
    return {
        cron = { enabled = enabled, expected = expected,
            matches = not cron_err and ((enabled and expected and #actual == 1 and actual[1] == expected) or (not enabled and #actual == 0)) or false,
            running = (sys.exec("pidof crond 2>/dev/null") or ""):match("%d+") ~= nil,
            actual = actual, error = cron_err },
        launcher = script_status(LAUNCHER, SCRIPT), hotplug = hook,
        last_auto = last_auto(log_file), log_window_bytes = READ_LIMIT
    }
end

return M
