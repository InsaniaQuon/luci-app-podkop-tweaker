-- Semantic snapshots use the native UCI parser, not LuCI's shared RPC cursor:
-- luci.model.uci.cursor() does not honor confdir/savedir in modern LuCI.
local LIB = require("podkop-tweaker.lib")
local SRV = require("podkop-tweaker.services")
local M = {}
M.CONFIG = "/etc/config/argon"
M.BACKUP = "/etc/podkop-tweaker-argon.backup"
local DELTA = "/tmp/pt-argon-theme/uci"
local RECOVERY = "/tmp/pt-argon-theme/recovery"
local DEFAULTS = { login_style = "classic", primary = "#5e72e4", dark_primary = "#483d8b", blur = "10",
    blur_dark = "10", transparency = "0.5", transparency_dark = "0.5", mode = "normal", online_wallpaper = "none" }

local function parse_export(raw)
    local statements, err = LIB.uci_statements(raw, true)
    if not statements then return nil, err end
    local sections, current, counts = {}, nil, {}
    for _, statement in ipairs(statements) do
        local t = statement.tokens
        if t[1] == "package" then
            if t[2] ~= "argon" then return nil, "Unexpected UCI package" end
        elseif t[1] == "config" and t[2] then
            counts[t[2]] = (counts[t[2]] or 0) + 1
            current = { name = t[3] or ("@" .. t[2] .. "[" .. (counts[t[2]] - 1) .. "]"),
                kind = t[2], anonymous = t[3] == nil, options = {} }
            sections[#sections + 1] = current
        elseif (t[1] == "option" or t[1] == "list") and current and t[2] and t[3] ~= nil then
            if t[1] == "option" then current.options[t[2]] = t[3]
            else
                local values = current.options[t[2]]
                if type(values) ~= "table" then values = values ~= nil and { values } or {}; current.options[t[2]] = values end
                values[#values + 1] = t[3]
            end
        else return nil, "Cannot parse native Argon UCI export" end
    end
    return sections
end

function M.snapshot(directory)
    directory = directory or "/etc/config"
    -- -t selects where UCI writes deltas, but libuci still reads /tmp/.uci.
    -- Refuse pending changes rather than mixing them into a disk-file backup.
    for _, path in ipairs({ "/tmp/.uci/argon", DELTA .. "/argon" }) do
        local changes, changes_err, changes_errno = io.open(path, "rb")
        if changes then
            local byte, read_err = changes:read(1)
            local closed = changes:close()
            if read_err or not closed then return nil, "Cannot inspect pending Argon UCI changes" end
            if byte then return nil, "Uncommitted Argon UCI changes are present; apply or discard them before updating" end
        elseif changes_errno ~= 2 then return nil, changes_err or "Cannot inspect pending Argon UCI changes" end
    end
    local fd, open_err, errno = io.open(directory .. "/argon", "rb")
    if not fd then
        if errno == 2 then return {} end
        return nil, open_err or "Cannot read Argon configuration"
    end
    local raw, read_err = SRV.read_stream(fd, LIB.UCI_MAX_SIZE)
    local closed = fd:close()
    if not raw or not closed then return nil, read_err or "Cannot close Argon configuration" end
    local pipe = io.popen("uci -q -c " .. LIB.shell_escape(directory) .. " -C '' -t " .. LIB.shell_escape(DELTA) ..
        " export argon 2>/dev/null; printf '\nPT_UCI_EXIT:%s\n' \"$?\"", "r")
    if not pipe then return nil, "Cannot start native UCI reader" end
    local output, output_err = SRV.read_stream(pipe, LIB.UCI_MAX_SIZE + 64)
    pipe:close()
    if not output then return nil, output_err end
    local exported, code = output:match("^(.*)\nPT_UCI_EXIT:(%d+)\n$")
    if code ~= "0" or not exported or #exported > LIB.UCI_MAX_SIZE then return nil, "Cannot export native Argon UCI" end
    return parse_export(exported)
end

function M.valid_snapshot(sections)
    if type(sections) ~= "table" or #sections > 256 then return false end
    local count = 0
    for _, s in ipairs(sections) do
        if type(s) ~= "table" or type(s.name) ~= "string" or type(s.kind) ~= "string" or
            type(s.anonymous) ~= "boolean" or type(s.options) ~= "table" then return false end
        for k, v in pairs(s.options) do
            count = count + 1
            if count > 4096 or type(k) ~= "string" then return false end
            if type(v) == "table" then
                for i, value in pairs(v) do
                    if type(i) ~= "number" or i < 1 or i ~= math.floor(i) or type(value) ~= "string" then return false end
                end
            elseif type(v) ~= "string" then return false end
        end
    end
    return true
end

function M.expected(original, integrated)
    local sections = {}
    for _, s in ipairs(original) do
        local options = {}
        for k, v in pairs(s.options) do options[k] = v end
        sections[#sections + 1] = { name = s.name, kind = s.kind, anonymous = s.anonymous, options = options }
    end
    if not integrated then return sections end
    local global
    for _, s in ipairs(sections) do if s.kind == "global" then global = s; break end end
    if not global then
        global = { name = "", kind = "global", anonymous = true, options = {} }
        sections[#sections + 1] = global
    end
    local o = global.options
    if o.bing_background and o.bing_background ~= "" then
        if o.online_wallpaper == nil then o.online_wallpaper = o.bing_background == "1" and "bing" or "none" end
        o.bing_background = nil
    end
    if o.dark_primary_mode == nil then o.dark_primary_mode = o.dark_primary and o.dark_primary ~= "" and "custom" or "auto" end
    if o.dark_glass_mode == nil then
        local function fallback(value, default) if value == nil or value == "" then return default end; return value end
        o.dark_glass_mode = fallback(o.blur_dark, fallback(o.blur, "10")) ~= fallback(o.blur, "10") or
            fallback(o.transparency_dark, fallback(o.transparency, "0.5")) ~= fallback(o.transparency, "0.5")
        o.dark_glass_mode = o.dark_glass_mode and "custom" or "inherit"
    end
    for k, v in pairs(DEFAULTS) do if o[k] == nil then o[k] = v end end
    return sections
end

local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    if #a ~= #b then return false end
    for i, value in ipairs(a) do if b[i] ~= value then return false end end
    return true
end

function M.verify(original, integrated, directory)
    local expected = M.expected(original, integrated)
    local current, err = M.snapshot(directory)
    if not M.valid_snapshot(current) then return false, err or "Cannot read resulting Argon UCI" end
    local ordinals = {}
    local first_global = true
    for _, before in ipairs(expected) do
        ordinals[before.kind] = (ordinals[before.kind] or 0) + 1
        local ordinal, after = 0, nil
        for _, s in ipairs(current) do
            if s.kind == before.kind then
                ordinal = ordinal + 1
                if before.anonymous and ordinal == ordinals[before.kind] or not before.anonymous and s.name == before.name then after = s; break end
            end
        end
        if not after then return false, "Argon section was not preserved: " .. before.kind end
        for k, v in pairs(before.options) do
            if not equal(v, after.options[k]) then return false, "Argon option was not preserved: " .. before.kind .. "." .. k end
        end
        if integrated and before.kind == "global" and first_global then
            if before.options.bing_background == nil and after.options.bing_background ~= nil then return false, "Argon Bing setting migration is incomplete" end
            first_global = false
        end
    end
    return true
end

local function quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function serialize(sections)
    local lines = {}
    for _, section in ipairs(sections) do
        lines[#lines + 1] = "config " .. quote(section.kind) .. (section.anonymous and "" or " " .. quote(section.name)) .. "\n"
        local keys = {}
        for key in pairs(section.options) do keys[#keys + 1] = key end
        table.sort(keys)
        for _, key in ipairs(keys) do
            local value = section.options[key]
            if type(value) == "table" then
                for _, item in ipairs(value) do lines[#lines + 1] = "\tlist " .. quote(key) .. " " .. quote(item) .. "\n" end
            else lines[#lines + 1] = "\toption " .. quote(key) .. " " .. quote(value) .. "\n" end
        end
        lines[#lines + 1] = "\n"
    end
    return table.concat(lines)
end

-- Restore only a missing config. Build and parse the candidate in a private
-- directory before atomic application; existing administrator edits stay intact.
function M.restore_missing(raw, original, integrated)
    local fd, open_err, errno = io.open(M.CONFIG, "rb")
    if fd then
        if not fd:close() then return false, "Cannot close Argon configuration" end
        return true
    end
    if errno ~= 2 then return false, open_err or "Cannot inspect Argon configuration" end
    if raw == "" and #original == 0 and not integrated then return true end
    local candidate = integrated and serialize(M.expected(original, true)) or raw
    local made = LIB.exit_ok(os.execute("umask 077; mkdir -p " .. RECOVERY))
    if not made then return false, "Cannot create private Argon recovery directory" end
    local staged, stage_err = SRV.write_file_atomic(RECOVERY .. "/argon", candidate, { mode = "600" })
    if not staged then return false, stage_err end
    local valid, validation_err = M.verify(original, integrated, RECOVERY)
    if not valid then return false, validation_err end
    return SRV.write_file_atomic(M.CONFIG, candidate, { mode = "600" })
end

return M
