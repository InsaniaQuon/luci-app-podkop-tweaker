-- APK lifecycle regressions. All files, downloads, package hooks and services
-- are in-memory fixtures; no host APK, curl, chmod or init script is executed.
package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path
local H = require("pt_harness")
local THEME, COMPAT = "luci-theme-argon", "luci-app-argon-config"
local RU, ZH, DE = "luci-i18n-argon-config-ru", "luci-i18n-argon-config-zh-cn", "luci-i18n-argon-config-de"
local CONFIG, BACKUP = "/etc/config/argon", "/etc/podkop-tweaker-argon.backup"
local STATE, CACHE = "/etc/podkop-tweaker-argon-update.json", "/tmp/pt_argon_theme_check.json"
local MIGRATION, STAGING = "/etc/argon-config-migration/argon", "/tmp/pt-argon-theme"
local RECOVERY = STAGING .. "/recovery/argon"
local CSS, RECORD = "/www/luci-static/argon/css/cascade.css", "/tmp/pt-web-restart.json"
local API = "https://api.github.com/repos/jerrykuku/luci-theme-argon/releases/latest"
local MANIFEST = "apk list --installed --manifest 2>/dev/null"
local ID = string.rep("a", 32)
local WEB_LOCK = "/var/lock/podkop-tweaker-web-update.lock"
local ARGON_LOCK = "/var/lock/podkop-tweaker-argon-css.lock"

local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = copy(v) end
    return result
end

-- Deliberately not a crypto implementation: the sha256sum process is mocked.
-- Stable, content-dependent identities let corruption tests distinguish bytes
-- instead of returning the expected digest for every arbitrary file.
local function checksum(bytes)
    local a, b = 1, 0
    for i = 1, #bytes do a = (a + bytes:byte(i)) % 65521; b = (b + a) % 65521 end
    return string.rep(string.format("%04x%04x", a, b), 8)
end

local function exit_output(text, code)
    return (text or "") .. "\nPT_EXIT:" .. tostring(code or 0) .. "\n"
end

local function uci_output(text, code)
    return (text or "") .. "\nPT_UCI_EXIT:" .. tostring(code or 0) .. "\n"
end

local function release_fixture(version, names)
    version = version or "3.0.0-r2"
    local base = version:match("^(%d+%.%d+%.%d+)")
    local response = { tag_name = "v" .. base, assets = {} }
    local bytes = {}
    for _, name in ipairs(names or { THEME, COMPAT, RU, ZH, DE }) do
        local filename = name .. "-" .. version .. ".apk"
        bytes[filename] = "\0APK fixture: " .. filename .. "\n"
        response.assets[#response.assets + 1] = { name = filename, size = #bytes[filename],
            digest = "sha256:" .. checksum(bytes[filename]),
            browser_download_url = "https://github.com/jerrykuku/luci-theme-argon/releases/download/v" .. base .. "/" .. filename }
    end
    return response, bytes
end

local function sections(mode, anonymous)
    local global = H.sec(anonymous and "cfg001" or "global", "global", {
        mode = mode or "dark", primary = "#abcdef", dark_primary = "#123456",
        blur = "8", blur_dark = "12", transparency = "0.4", transparency_dark = "0.7",
        bing_background = "1", future_option = "retain this value"
    })
    global[".anonymous"] = anonymous == true
    return { global,
        H.sec("typography", "typography", { font_size = "17", font_weight = "550",
            font_family = "custom", font_family_custom = "Local Sans, monospace", line_height = "1.5",
            letter_spacing = "0.2", menu_font_size = "1.1", menu_padding = "11", future_font = "keep" }),
        H.sec("future", "unknown_plugin", { opaque = "not theme-owned", order = { "first", "second", "third" },
            multiline = "first line\nsecond line" }) }
end

local function uci_quote(value)
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function options(section)
    local values = {}
    for key, value in pairs(section) do if key:sub(1, 1) ~= "." then values[key] = copy(value) end end
    return values
end

local function raw_uci(config)
    local out = { "# user's complete Argon config, including unknown sections\n" }
    for _, section in ipairs(config) do
        out[#out + 1] = "config " .. uci_quote(section[".type"]) .. (section[".anonymous"] and "" or " " .. uci_quote(section[".name"])) .. "\n"
        local keys = {}
        for key in pairs(section) do if key:sub(1, 1) ~= "." then keys[#keys + 1] = key end end
        table.sort(keys)
        for _, key in ipairs(keys) do
            local value = section[key]
            if type(value) == "table" then
                for _, item in ipairs(value) do out[#out + 1] = "\tlist " .. uci_quote(key) .. " " .. uci_quote(item) .. "\n" end
            else out[#out + 1] = "\toption " .. uci_quote(key) .. " " .. uci_quote(value) .. "\n" end
        end
        out[#out + 1] = "\n"
    end
    return table.concat(out)
end

-- Independent fixture parser for the package hook / native CLI boundary. It
-- never calls LIB.uci_statements or CFG.snapshot: doing so would make a broken
-- production lexer validate its own output. In particular, production-generated
-- recovery candidates must be understood from their actual VFS bytes.
local function fixture_config(raw)
    local statements, words, chars = {}, {}, {}
    local quote, escaped, comment, started = nil, false, false, false
    local function word()
        if started then words[#words + 1] = table.concat(chars) end
        chars, started = {}, false
    end
    local function statement()
        word()
        if #words > 0 then statements[#statements + 1] = words end
        words = {}
    end
    for i = 1, #raw do
        local ch = raw:sub(i, i)
        if comment then
            if ch == "\n" then comment = false; statement() end
        elseif escaped then
            if ch ~= "\n" and ch ~= "\r" then chars[#chars + 1] = ch end
            escaped = false
        elseif quote then
            if ch == quote then quote = nil
            elseif quote == '"' and ch == "\\" then escaped = true
            else chars[#chars + 1] = ch end
        elseif ch == "\\" then started, escaped = true, true
        elseif ch == "'" or ch == '"' then started, quote = true, ch
        elseif ch == "#" and not started then comment = true
        elseif ch == "\n" then statement()
        elseif ch == " " or ch == "\t" or ch == "\r" then word()
        else chars[#chars + 1], started = ch, true end
    end
    if quote or escaped then return nil, "Invalid quoted fixture UCI" end
    statement()
    local config, current, counts = {}, nil, {}
    for _, tokens in ipairs(statements) do
        local directive = tokens[1]
        if directive == "package" and #tokens == 2 and tokens[2] == "argon" then
            -- uci export's package header is not present in a plain conffile.
        elseif directive == "config" and (#tokens == 2 or #tokens == 3) then
            counts[tokens[2]] = (counts[tokens[2]] or 0) + 1
            local name = tokens[3] or ("@" .. tokens[2] .. "[" .. (counts[tokens[2]] - 1) .. "]")
            current = H.sec(name, tokens[2])
            if not tokens[3] then current[".anonymous"] = true end
            config[#config + 1] = current
        elseif current and #tokens == 3 and directive == "option" then current[tokens[2]] = tokens[3]
        elseif current and #tokens == 3 and directive == "list" then
            local previous = current[tokens[2]]
            if type(previous) ~= "table" then previous = previous ~= nil and { previous } or {}; current[tokens[2]] = previous end
            previous[#previous + 1] = tokens[3]
        else return nil, "Invalid native fixture UCI directive" end
    end
    return config
end

-- This models the package hook, independently of theme_config.expected().
-- Tests assert the resulting user values, not equality with that helper.
local function native_migration(config)
    config = copy(config)
    local global
    for _, section in ipairs(config) do if section[".type"] == "global" then global = section; break end end
    if not global then
        global = H.sec("cfg_new", "global", { [".anonymous"] = true })
        config[#config + 1] = global
    end
    if global.bing_background and global.bing_background ~= "" then
        if global.online_wallpaper == nil then global.online_wallpaper = global.bing_background == "1" and "bing" or "none" end
        global.bing_background = nil
    end
    if global.dark_primary_mode == nil then global.dark_primary_mode = global.dark_primary and global.dark_primary ~= "" and "custom" or "auto" end
    if global.dark_glass_mode == nil then
        -- Upstream shell uses ${var:-fallback}: both unset and empty values
        -- fall back for comparison, without changing the original UCI value.
        local function shell_default(value, fallback)
            if value == nil or value == "" then return fallback end
            return value
        end
        local light_blur = shell_default(global.blur, "10")
        local light_opacity = shell_default(global.transparency, "0.5")
        local different = shell_default(global.blur_dark, light_blur) ~= light_blur or
            shell_default(global.transparency_dark, light_opacity) ~= light_opacity
        global.dark_glass_mode = different and "custom" or "inherit"
    end
    local defaults = { login_style = "classic", primary = "#5e72e4", dark_primary = "#483d8b", blur = "10",
        blur_dark = "10", transparency = "0.5", transparency_dark = "0.5", mode = "normal", online_wallpaper = "none" }
    for key, value in pairs(defaults) do if global[key] == nil then global[key] = value end end
    return config
end

local function manifest(packages)
    local lines = {}
    for name, version in pairs(packages) do lines[#lines + 1] = name .. " " .. version .. "\n" end
    table.sort(lines)
    return table.concat(lines)
end

local function has_command(commands, fragment)
    for _, command in ipairs(commands) do if command:find(fragment, 1, true) then return true end end
    return false
end

local function no_restart()
    assert.is_false(has_command(H.exec_cmds(), "uhttpd restart"))
    assert.is_false(has_command(H.execute_cmds(), "uhttpd restart"))
end

local function no_finish()
    no_restart()
    assert.is_false(has_command(H.exec_cmds(), "/etc/init.d/rpcd reload"))
    assert.is_false(has_command(H.exec_cmds(), "rm -rf /tmp/luci-"))
end

local function stage_pattern(target, suffix)
    return target .. (suffix or ".tmp-write") .. ".*"
end

local function fail_stage(target, operation, partial, suffix)
    H.state().failures[operation == "rename" and target or stage_pattern(target, suffix)] = {
        [operation] = true, partial = partial
    }
end

local function private_stages(target, suffix)
    local pattern = target and stage_pattern(target, suffix) or nil
    local allocations = H.allocations(pattern)
    assert.is_true(#allocations > 0, "No real unique stage allocated for " .. tostring(target or "this operation"))
    local selected, modes = {}, {}
    for _, allocation in ipairs(allocations) do
        assert.equal("600", allocation.mode, "mktemp must reserve private bytes before a writer opens the stage")
        assert.is_nil(selected[allocation.path], "A physical stage pathname was reused")
        selected[allocation.path] = true
    end
    for _, event in ipairs(H.state().io_log) do
        if selected[event.path] then
            if event.operation == "mktemp" and event.success or event.operation == "chmod" and event.success then
                modes[event.path] = event.mode
            elseif event.operation == "write" then
                assert.equal("600", modes[event.path], "Stage was not private before bytes: " .. event.path)
            end
        end
    end
    return H.stage_paths(pattern)
end

local function no_stages_left(target, suffix)
    for _, path in ipairs(H.stage_paths(stage_pattern(target, suffix))) do assert.falsy(H.vfs_exists(path), path) end
end

local function mode_failure(target, mode, suffix)
    local prefix = "chmod " .. mode .. " '" .. target .. (suffix or ".tmp-write") .. "."
    return function(command) if command:find(prefix, 1, true) == 1 then return 1 end end
end

local CHECKED_END = ") </dev/null 2>&1; printf '\\nPT_EXIT:%s\\n' \"$?\""
local function checked_body(command)
    if command:sub(1, 1) == "(" and command:sub(-#CHECKED_END) == CHECKED_END then
        return command:sub(2, #command - #CHECKED_END)
    end
end

local function begin(opts)
    opts = opts or {}
    local c = { installed = copy(opts.installed or { ["base-files"] = "1666~native-r1", [THEME] = "2.4.8-r2" }),
        target = opts.target or "3.0.0-r2", exports = {}, export_overrides = {}, installs = {}, downloaded = {},
        hash_calls = {}, preconditions = {},
        command_failures = {}, download_failures = {}, hash_overrides = {}, statuses = {}, github_calls = 0 }
    c.github, c.bytes = release_fixture(c.target, opts.assets)
    c.asset_by_name = {}
    for _, asset in ipairs(c.github.assets) do
        c.asset_by_name[asset.name:match("^(.*)%-%d+%.%d+%.%d+%-r%d+%.apk$")] = asset
    end
    c.write_config = function(config, path)
        local raw = raw_uci(config)
        H.vfs_write(path or CONFIG, raw)
        return raw
    end
    c.read_config = function(path)
        local raw = H.vfs_read(path or CONFIG)
        if not raw then return {} end
        local config, err = fixture_config(raw)
        assert(config, err)
        return config
    end
    c.remove_config = function() os.remove(CONFIG) end
    c.perform_install = function(name)
        c.installed[name] = c.target
        if name == COMPAT and c.target:match("^3%.") then
            local raw = H.vfs_read(CONFIG)
            if raw then H.vfs_write(MIGRATION, raw); c.remove_config() end
        elseif name == THEME then
            -- The real theme hook consumes the migration file BEFORE looking
            -- at the live config. Reversing this priority masks lost-user-edit bugs.
            local handoff = H.vfs_read(MIGRATION)
            if handoff then H.vfs_write(CONFIG, handoff); os.remove(MIGRATION) end
            local config = c.read_config()
            if c.target:match("^3%.") then config = native_migration(config) end
            c.write_config(config)
            H.vfs_write(CSS, ".new-argon-package{}\n")
        end
    end
    local checked_commands = {
        ["umask 077; mkdir -p " .. STAGING .. "/uci && chmod 700 " .. STAGING .. " " .. STAGING .. "/uci"] = true,
        ["umask 077; mkdir -p /etc/argon-config-migration && chmod 700 /etc/argon-config-migration"] = true,
        ["/etc/init.d/rpcd reload"] = true, ["rm -rf /tmp/luci-*"] = true, ["rm -rf " .. STAGING] = true
    }
    local function fixture_sys(command)
        return command == MANIFEST or command == "apk --version 2>/dev/null" or command == "pidof uhttpd 2>/dev/null" or
            command:find("apk query ", 1, true) == 1 or command:find("sha256sum ", 1, true) == 1 or
            checked_commands[checked_body(command)] == true or
            (checked_body(command) or ""):find("cd / && apk add ", 1, true) == 1
    end
    local function sys(command)
        if command == MANIFEST then return c.manifest_override or manifest(c.installed) end
        if command == "apk --version 2>/dev/null" then return opts.apk_version or "apk-tools 3.0.3, compiled for aarch64.\n" end
        if command == "pidof uhttpd 2>/dev/null" then return "100\n" end
        if command:find("apk query ", 1, true) then
            local name = command:match("%-%-match name '([^']+)' 2>/dev/null$")
            if not name then return "bad status command" end
            if c.statuses[name] ~= nil then return type(c.statuses[name]) == "string" and c.statuses[name] or H.json.stringify(c.statuses[name]) end
            return H.json.stringify(c.installed[name] and { { name = name, version = c.installed[name], status = { "installed" } } } or {})
        end
        if command:find("sha256sum ", 1, true) then
            local path = command:match("^sha256sum '([^']+)' 2>/dev/null$")
            c.hash_calls[#c.hash_calls + 1] = path or command
            if c.hash_overrides[path] ~= nil then return c.hash_overrides[path] or "" end
            local raw = H.vfs_read(path)
            return raw and checksum(raw) .. "  " .. path .. "\n" or ""
        end
        for fragment, failure in pairs(c.command_failures) do
            if command:find(fragment, 1, true) then return failure end
        end
        if command:find("apk add ", 1, true) then
            local filename = command:match("apk add %-%-allow%-untrusted '/tmp/pt%-argon%-theme/([^']+)'%)")
            local name = filename and filename:match("^(.*)%-%d+%.%d+%.%d+%-r%d+%.apk$")
            c.installs[#c.installs + 1] = name or command
            local ready = { backup = H.vfs_read(BACKUP), state = H.json.parse(H.vfs_read(STATE) or ""),
                backup_mode = H.vfs_mode(BACKUP), state_mode = H.vfs_mode(STATE), hashes = copy(c.hash_calls), packages = {} }
            for _, asset in pairs(c.asset_by_name) do ready.packages[asset.name] = H.vfs_read(STAGING .. "/" .. asset.name) end
            c.preconditions[#c.preconditions + 1] = ready
            if c.install_override then return c.install_override(name, command) end
            c.perform_install(name)
            return exit_output("Installed " .. name)
        end
        assert.is_true(checked_commands[checked_body(command)] == true, "Unexpected theme fixture command: " .. command)
        return exit_output()
    end
    local function execute(command)
        if c.execute_override then
            local result = c.execute_override(command)
            if result ~= nil then return result end
        end
        -- Permissions, mktemp and mkdir/rmdir locks belong to the harness's
        -- native model. Only these two external effects are explicit successes.
        if command == "umask 077; mkdir -p " .. STAGING .. "/recovery" or
            command:find("sleep 1; /etc/init.d/uhttpd restart", 1, true) then return 0 end
    end
    H.begin({ strict = true, sys = { { match = fixture_sys, out = sys } },
        uci = { argon = { H.sec("rpc_stale", "global", { mode = "light", future_option = "RPC cursor ignores confdir" }) } },
        execute = { { match = function(command)
            return command:match("^chmod [0-7]+ '[^']+' 2>/dev/null$") ~= nil or
                command == "umask 077; mkdir -p " .. STAGING .. "/recovery" or
                command:find("sleep 1; /etc/init.d/uhttpd restart", 1, true) ~= nil
        end, out = execute } }, failures = opts.failures,
        popen = function(command)
            if command:find("uci -q -c ", 1, true) == 1 then
                local directory, savedir = command:match("^uci %-q %-c '([^']+)' %-C '' %-t '([^']+)' export argon 2>/dev/null; printf ")
                if not directory or savedir ~= STAGING .. "/uci" then return uci_output("", 1) end
                local expected_command = "uci -q -c '" .. directory .. "' -C '' -t '" .. savedir .. "' export argon 2>/dev/null; printf '\nPT_UCI_EXIT:%s\n' \"$?\""
                if command ~= expected_command then return uci_output("", 1) end
                local path = directory .. "/argon"
                local raw = H.vfs_read(path)
                c.exports[#c.exports + 1] = { directory = directory, savedir = savedir, path = path, raw = raw, command = command }
                local override = c.export_overrides[directory]
                if type(override) == "function" then return override(raw, command) end
                if override ~= nil then return override end
                if not raw or not fixture_config(raw) then return uci_output("", 1) end
                return uci_output("package argon\n\n" .. raw)
            end
            if command:find("'" .. API .. "'", 1, true) then
                c.github_calls = c.github_calls + 1
                return (c.github_raw or H.json.stringify(c.github)) .. "\nPT_CURL_EXIT:0\n"
            end
            for _, asset in pairs(c.asset_by_name) do
                if command:find("'" .. asset.browser_download_url .. "'", 1, true) then
                    c.downloaded[#c.downloaded + 1] = asset.name
                    if c.on_download then c.on_download(asset) end
                    return c.download_failures[asset.name] or c.bytes[asset.name] .. "\nPT_CURL_EXIT:0\n"
                end
            end
            -- nil delegates to the harness; never turn native mktemp into a
            -- fake curl failure or replace numeric EOF with an empty string.
            return nil
        end })
    H.vfs_write("/etc/openwrt_release", "DISTRIB_ID='OpenWrt'\nDISTRIB_RELEASE='" .. (opts.openwrt or "25.12.4") .. "'\n")
    H.vfs_write("/proc/100/stat", "100 (uhttpd) S " .. string.rep("0 ", 18) .. "1000\n")
    H.vfs_write(CSS, ".original-argon{}\n")
    c.original_sections = copy(opts.config or sections(opts.mode, opts.anonymous))
    if not opts.missing_config then c.original_raw = c.write_config(c.original_sections) end
    c.theme = require("podkop-tweaker.theme")
    -- 4.11.0: the synchronous web_restart wrapper is gone. Tests drive the same
    -- flow the CLI worker runs: register the admitted job, execute the worker
    -- body in-process and report its finalized result.
    local WORKER = require("podkop-tweaker.theme_worker")
    c.theme.update = function(id)
        local job_id = id or string.rep("c", 32)
        assert.is_true(WORKER.write_job({ schema = 1, id = job_id, state = "queued", created = os.time(), history = {} }))
        local code = WORKER.run(job_id)
        local status = WORKER.status(job_id)
        local result = status.result
        if type(result) ~= "table" then
            result = { success = false, error = status.error or ("Theme worker exited with code " .. tostring(code)) }
        end
        result.restart_id = id
        return result
    end
    c.pkg = require("podkop-tweaker.theme_packages")
    c.cfg = require("podkop-tweaker.theme_config")
    c.snapshot = function(directory)
        local snapshot, err = c.cfg.snapshot(directory)
        assert(snapshot, err)
        return snapshot
    end
    c.cache = function(age)
        H.vfs_write(CACHE, H.json.stringify({ schema = 2, cached_at = os.time() - (age or 0), release = c.pkg.release(c.github) }))
    end
    return c
end

local function failed(c, phase)
    local response = c.theme.update()
    assert.is_false(response.success, response.error or "update falsely succeeded")
    assert.equal(phase, response.phase, response.error or response.details)
    no_restart()
    return response
end

after_each(function() H.finish() end)

describe("Argon typography/update coordination", function()
    it("includes a concurrent Typography Save during download in the original raw and semantic baseline", function()
        local c = begin()
        local saved, latest_raw
        H.state().uci.argon = copy(c.original_sections)
        H.state().uci["podkop-tweaker"] = { H.sec("settings", "settings", { show_argon_tab = "1" }) }
        local uci = require("luci.model.uci").cursor()
        -- This scenario models the native RPC get_all/commit boundary explicitly:
        -- a successful real Save commits the selected package to its VFS conffile.
        -- Native CLI snapshots still use the independent byte parser above.
        uci.get_all = function(_, package)
            assert.equal("argon", package)
            local result = {}
            for _, section in ipairs(H.state().uci.argon) do result[section[".name"]] = copy(section) end
            return result
        end
        local commit = uci.commit
        uci.commit = function(self, package)
            local ok, err = commit(self, package)
            if ok and package == "argon" then
                assert.truthy(H.vfs_exists(ARGON_LOCK))
                latest_raw = c.write_config(H.state().uci.argon)
            end
            return ok, err
        end
        local settings = options(c.original_sections[2])
        settings.font_size, settings.font_weight, settings.line_height = "19", "650", "1.7"
        c.on_download = function()
            c.on_download = nil
            assert.falsy(H.vfs_exists(ARGON_LOCK), "network IO must not lock the typography form")
            assert.falsy(H.vfs_exists(BACKUP))
            assert.same({}, c.installs)
            local save = coroutine.create(function() saved = require("podkop-tweaker.api_argon").typography_save(settings) end)
            local resumed, err = coroutine.resume(save)
            assert.is_true(resumed, err)
            assert.equal("dead", coroutine.status(save))
            assert.is_true(saved.success, saved.error)
            assert.is_true(saved.uci_saved)
            assert.is_true(saved.css_applied)
            assert.is_string(latest_raw)
            assert.is_not.equal(c.original_raw, latest_raw)
            assert.matches("font-size: 19px", H.vfs_read(CSS), 1, true)
            assert.falsy(H.vfs_exists(ARGON_LOCK))
        end
        c.install_override = function(name)
            assert.truthy(H.vfs_exists(ARGON_LOCK), "the package hook must share the typography resource")
            c.perform_install(name)
            return exit_output()
        end
        local response = c.theme.update(ID)
        assert.is_true(response.success, response.error or response.details)
        assert.is_true(saved.success)
        assert.equal(latest_raw, H.vfs_read(BACKUP))
        local first = c.preconditions[1]
        assert.equal(latest_raw, first.backup)
        assert.equal(checksum(latest_raw), first.state.backup_sha256)
        local typography = first.state.original[2].options
        assert.equal("19", typography.font_size)
        assert.equal("650", typography.font_weight)
        assert.equal("1.7", typography.line_height)
        assert.equal("keep", typography.future_font)
        assert.same(options(c.original_sections[3]), first.state.original[3].options)
        assert.same(typography, c.snapshot()[2].options)
        assert.matches("font-size: 19px", H.vfs_read(CSS), 1, true)
        assert.matches("font-weight: 650", H.vfs_read(CSS), 1, true)
        assert.same({ "argon" }, H.commits())
        assert.falsy(H.vfs_exists(ARGON_LOCK))
    end)

    it("allows verified predownloads while argon-css is occupied but preserves the backup and avoids every package hook", function()
        local c = begin({ installed = { ["base-files"] = "native-r1", [THEME] = "2.4.8-r2", [COMPAT] = "2.4.6-r1", [ZH] = "0" } })
        H.vfs_mkdir(ARGON_LOCK)
        H.vfs_write(ARGON_LOCK .. "/owner", "concurrent typography operation")
        H.vfs_write(BACKUP, "previous usable recovery backup")
        c.on_download = function()
            assert.truthy(H.vfs_exists(ARGON_LOCK))
            assert.equal("previous usable recovery backup", H.vfs_read(BACKUP))
        end
        local response = c.theme.update(ID)
        assert.is_false(response.success)
        assert.matches("argon%-css", response.lock_error)
        assert.is_false(response.partial)
        assert.is_false(response.resume_available)
        assert.falsy(response.applied)
        assert.equal(3, #c.downloaded)
        for _, name in ipairs({ COMPAT, THEME, ZH }) do
            local asset = c.asset_by_name[name]
            local path = STAGING .. "/" .. asset.name
            assert.equal(c.bytes[asset.name], H.vfs_read(path))
            assert.equal("600", H.vfs_mode(path))
            assert.is_true(has_command(c.hash_calls, path), "the predownload must be verified before attempting the lock")
        end
        assert.same({}, c.installs)
        assert.same({}, c.exports)
        assert.same({}, H.stage_paths(stage_pattern(BACKUP)))
        assert.same({}, H.stage_paths(stage_pattern(STATE)))
        assert.equal("previous usable recovery backup", H.vfs_read(BACKUP))
        assert.equal(c.original_raw, H.vfs_read(CONFIG))
        assert.equal(".original-argon{}\n", H.vfs_read(CSS))
        assert.falsy(H.vfs_exists(STATE))
        assert.equal("concurrent typography operation", H.vfs_read(ARGON_LOCK .. "/owner"))
        assert.truthy(H.vfs_exists(ARGON_LOCK))
        no_finish()
    end)

    for _, operation in ipairs({ "open", "read", "close" }) do
        it("blocks finishing after a post-publication stale-status " .. operation .. " error and retains recovery", function()
            local c = begin()
            local SRV = require("podkop-tweaker.services")
            local publish = SRV.publish_file
            local injected = false
            SRV.publish_file = function(stage, target)
                local ok, err = publish(stage, target)
                if ok and target == CSS then
                    injected = true
                    H.state().failures[CSS] = { [operation] = true }
                end
                return ok, err
            end
            local response = c.theme.update(ID)
            assert.is_true(injected, "failure must occur after checked CSS publication, not during injection")
            assert.is_false(response.success)
            assert.equal("Cannot verify Argon typography CSS", response.error)
            assert.matches("Injected " .. operation .. " failure", response.details, 1, true)
            assert.equal("css", response.phase)
            assert.is_true(response.partial)
            assert.is_true(response.resume_available)
            assert.same({ THEME }, c.installs)
            assert.equal(c.target, c.installed[THEME])
            assert.equal(c.original_raw, H.vfs_read(BACKUP))
            assert.equal("600", H.vfs_mode(BACKUP))
            local recovery = H.json.parse(H.vfs_read(STATE))
            assert.equal("css", recovery.phase)
            assert.is_true(recovery.changed)
            assert.equal(checksum(c.original_raw), recovery.backup_sha256)
            assert.equal("600", H.vfs_mode(STATE))
            assert.matches("font-size: 17px", H.vfs_read(CSS), 1, true)
            H.vfs_write("/proc/100/stat", "100 (uhttpd) S " .. string.rep("0 ", 18) .. "2000\n")
            assert.truthy(require("podkop-tweaker.api_update").restart_status(ID).error,
                "a failed theme job writes no restart evidence")
            no_finish()
        end)
    end

    it("retains primary package diagnostics and recovery metadata after an argon-css release failure", function()
        local c = begin({ failures = { [ARGON_LOCK] = { rmdir = true } } })
        local output = "Primary APK hook failure\n" .. string.rep("complete native output <plain-text>\n", 500) .. "primary-output-end"
        local primary = "Argon package installation failed: " .. THEME
        c.install_override = function(name)
            c.perform_install(name)
            return exit_output(output, 1)
        end
        local response = c.theme.update(ID)
        assert.is_false(response.success)
        assert.is_true(response.unknown)
        assert.falsy(response.applied, "neither entering install nor lock release failure proves full application")
        assert.matches(primary, response.details, 1, true)
        assert.matches("argon%-css", response.lock_error)
        assert.truthy(H.vfs_exists(ARGON_LOCK))
        assert.matches(output, response.details, 1, true)
        assert.equal("theme", response.phase)
        assert.is_true(response.partial)
        assert.is_true(response.resume_available)
        assert.equal(ID, response.restart_id)
        assert.same({ THEME }, c.installs)
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        assert.equal("theme", H.json.parse(H.vfs_read(STATE)).phase)
        assert.equal("600", H.vfs_mode(STATE))
        H.vfs_write("/proc/100/stat", "100 (uhttpd) S " .. string.rep("0 ", 18) .. "2000\n")
        assert.truthy(require("podkop-tweaker.api_update").restart_status(ID).error)
        no_finish()
    end)
end)

describe("Argon independent legacy handoff", function()
    local function legacy()
        return begin({ installed = { ["base-files"] = "native-r1", [THEME] = "2.4.8-r2", [COMPAT] = "2.4.6-r1" } })
    end

    it("supplies the verified original when a successful compat hook leaves no handoff", function()
        local c = legacy()
        c.install_override = function(name)
            c.perform_install(name)
            if name == COMPAT then os.remove(MIGRATION) end
            return exit_output()
        end
        local response = c.theme.update()
        assert.is_true(response.success, response.error)
        assert.same({ COMPAT, THEME }, c.installs)
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        assert.equal("retain this value", c.snapshot()[1].options.future_option)
        assert.falsy(H.vfs_exists(MIGRATION))
    end)

    it("stops before theme installation when the compat handoff differs from the original", function()
        local c = legacy()
        c.install_override = function(name)
            c.perform_install(name)
            if name == COMPAT then H.vfs_write(MIGRATION, "conflicting administrator file") end
            return exit_output()
        end
        local response = failed(c, "compat")
        assert.matches("handoff differs", response.error, 1, true)
        assert.same({ COMPAT }, c.installs)
        assert.equal("conflicting administrator file", H.vfs_read(MIGRATION))
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        no_finish()
    end)

    it("does not recreate a stale upstream handoff while resuming finishing stages", function()
        local c = legacy()
        c.command_failures["/etc/init.d/rpcd reload"] = exit_output("reload failed", 1)
        failed(c, "rpcd")
        assert.falsy(H.vfs_exists(MIGRATION))
        c.command_failures["/etc/init.d/rpcd reload"] = nil
        local response = c.theme.update()
        assert.is_true(response.success, response.error)
        assert.same({ COMPAT, THEME }, c.installs)
        assert.falsy(H.vfs_exists(MIGRATION), "old settings must not be replayed by a future upstream update")
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
    end)

    it("refuses Resume after completed compat when the administrator restores/edits current and removes the handoff", function()
        local c = legacy()
        c.install_override = function(name)
            if name == THEME then return exit_output("theme installation failed before its hook", 1) end
            c.perform_install(name)
            return exit_output()
        end
        local first = failed(c, "theme")
        assert.is_true(first.partial)
        assert.equal(c.original_raw, H.vfs_read(MIGRATION))
        assert.is_true(H.json.parse(H.vfs_read(STATE)).steps[1].done)
        local edited = copy(c.original_sections)
        edited[1].mode, edited[1].future_option = "light", "administrator repair must survive"
        local administrator_raw = c.write_config(edited)
        os.remove(MIGRATION)
        c.install_override = nil
        local response = failed(c, "compat")
        assert.matches("changed since the saved original", response.error, 1, true)
        assert.is_true(response.partial)
        assert.is_true(response.resume_available)
        assert.same({ COMPAT, THEME }, c.installs)
        assert.equal(administrator_raw, H.vfs_read(CONFIG))
        assert.falsy(H.vfs_exists(MIGRATION), "Resume must not recreate a higher-priority stale handoff over an administrator repair")
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        assert.equal("3.0.0-r2", H.json.parse(H.vfs_read(STATE)).release.version)
        no_finish()
    end)
end)

describe("Argon router APK compat recovery", function()
    local function failed_compat_hook()
        local c = begin({ apk_version = "apk-tools 3.0.5, compiled for aarch64.\n",
            installed = { ["base-files"] = "native-r1", [THEME] = "2.4.8-r2", [COMPAT] = "2.4.6-r1" } })
        c.install_override = function(name)
            if name ~= COMPAT then return exit_output("Unexpected automatic package command", 99) end
            -- The failed hook changed APK inventory/status but never completed
            -- its config handoff, matching the observed router recovery state.
            c.installed[COMPAT] = c.target
            for _, package in ipairs({ COMPAT, THEME }) do
                c.statuses[package] = { { name = package, version = c.installed[package], status = { "installed", "broken-script" } } }
            end
            return exit_output("Executing luci-app-argon-config-3.0.0-r2.post-install\nscript exited with error 127", 127)
        end
        local response = failed(c, "compat")
        assert.matches("Argon package installation failed: " .. COMPAT, response.error, 1, true)
        assert.matches("script exited with error 127", response.details, 1, true)
        assert.is_true(response.partial)
        assert.is_true(response.resume_available)
        assert.same({ COMPAT }, c.installs)
        assert.equal("3.0.0-r2", c.installed[COMPAT])
        assert.equal("2.4.8-r2", c.installed[THEME])
        assert.equal(c.original_raw, H.vfs_read(CONFIG))
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        assert.falsy(H.vfs_exists(MIGRATION))
        local plan = H.json.parse(H.vfs_read(STATE))
        assert.equal("compat", plan.phase)
        assert.is_true(plan.changed)
        assert.equal("3.0.0-r2", plan.release.version)
        assert.equal(checksum(c.original_raw), plan.backup_sha256)
        assert.same({ { name = COMPAT, phase = "compat" }, { name = THEME, phase = "theme" } }, plan.steps)
        assert.equal(1, c.github_calls)
        no_finish()
        return c, plan
    end

    local function administrator_removes_only_empty_compat(c)
        local pinned = H.vfs_read(STATE)
        -- Explicit administrator work is outside the updater. Removing the
        -- empty compatibility package must not pretend to repair old Argon.
        c.installed[COMPAT], c.statuses[COMPAT] = nil, nil
        H.vfs_write(CONFIG, c.original_raw)
        assert.same({ ["base-files"] = "native-r1", [THEME] = "2.4.8-r2" }, c.installed)
        assert.same({ "installed", "broken-script" }, c.statuses[THEME][1].status)
        assert.equal(pinned, H.vfs_read(STATE))
        assert.equal(c.original_raw, H.vfs_read(CONFIG))
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        assert.falsy(H.vfs_exists(MIGRATION))
        c.github = release_fixture("3.1.0-r1")
    end

    local function successful_package_install(c, name)
        c.perform_install(name)
        -- A new successful install repairs this package's own broken-script
        -- flag. Other installed packages retain their real, independent status.
        c.statuses[name] = nil
    end

    local function assert_recovered(c, original_plan)
        assert.same({ COMPAT, COMPAT, THEME }, c.installs)
        assert.same({ ["base-files"] = "native-r1", [COMPAT] = "3.0.0-r2", [THEME] = "3.0.0-r2" }, c.installed)
        assert.is_nil(c.statuses[COMPAT])
        assert.is_nil(c.statuses[THEME])
        assert.equal(1, c.github_calls, "Resume must keep the pinned release rather than requesting a newer target")
        assert.same({ c.asset_by_name[COMPAT].name, c.asset_by_name[THEME].name }, c.downloaded)
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        assert.equal(original_plan.backup_sha256, checksum(H.vfs_read(BACKUP)))
        assert.falsy(H.vfs_exists(STATE))
        assert.falsy(H.vfs_exists(MIGRATION))
        local config = c.snapshot()
        assert.equal("dark", config[1].options.mode)
        assert.equal("retain this value", config[1].options.future_option)
        assert.equal("bing", config[1].options.online_wallpaper)
        assert.same(options(c.original_sections[2]), config[2].options)
        assert.same(options(c.original_sections[3]), config[3].options)
        assert.matches("font-size: 17px", H.vfs_read(CSS), 1, true)
        for _, ready in ipairs(c.preconditions) do
            assert.equal(c.original_raw, ready.backup)
            assert.equal("3.0.0-r2", ready.state.release.version)
            assert.same(original_plan.original, ready.state.original)
            assert.equal(original_plan.backup_sha256, ready.state.backup_sha256)
        end
        local compat_path = STAGING .. "/" .. c.asset_by_name[COMPAT].name
        assert.equal(c.bytes[c.asset_by_name[COMPAT].name], c.preconditions[2].packages[c.asset_by_name[COMPAT].name])
        local verifications = 0
        for _, path in ipairs(c.preconditions[2].hashes) do if path == compat_path then verifications = verifications + 1 end end
        assert.is_true(verifications >= 2, "the pinned staged compatibility APK must be reverified before reinstall")
        local install_commands = {}
        for _, command in ipairs(H.exec_cmds()) do
            if command:find("apk add ", 1, true) then install_commands[#install_commands + 1] = command end
            assert.falsy(command:find("apk del", 1, true), "the updater must not remove administrator-selected packages")
            assert.falsy(command:find("apk fix", 1, true))
            assert.falsy(command:find("apk upgrade", 1, true))
        end
        assert.equal(#c.installs, #install_commands)
        for i, name in ipairs(c.installs) do
            local prefix = "(cd / && apk add --allow-untrusted '" .. STAGING .. "/" .. c.asset_by_name[name].name .. "') </dev/null 2>&1; printf "
            assert.equal(prefix, install_commands[i]:sub(1, #prefix), "checked APK installs must work with a closed request stdin")
            assert.matches("PT_EXIT:%s", install_commands[i], 1, true)
        end
        assert.is_true(has_command(H.execute_cmds(), "sleep 1; /etc/init.d/uhttpd restart"))
    end

    it("reinstalls only the manually removed empty compat from pinned verified bytes and upgrades the old broken theme", function()
        local c, original_plan = failed_compat_hook()
        administrator_removes_only_empty_compat(c)
        c.install_override = function(name)
            successful_package_install(c, name)
            return exit_output("Installed " .. name)
        end
        local response = c.theme.update()
        assert.is_true(response.success, response.error or response.details)
        assert.equal("3.0.0-r2", response.new_version)
        assert_recovered(c, original_plan)
    end)

    it("stops on a global APK error despite healthy reinstalled compat and waits for another explicit Resume", function()
        local c, original_plan = failed_compat_hook()
        administrator_removes_only_empty_compat(c)
        local output = "Installed luci-app-argon-config-3.0.0-r2\n" ..
            "ERROR: existing luci-theme-argon-2.4.8-r2 has broken-script status\n1 error"
        c.install_override = function(name)
            successful_package_install(c, name)
            return exit_output(output, 1)
        end
        local response = failed(c, "compat")
        assert.matches("Argon package installation failed: " .. COMPAT, response.error, 1, true)
        assert.matches(output, response.details, 1, true)
        assert.matches("Selected package is installed at 3.0.0-r2 with healthy APK status", response.details, 1, true)
        assert.matches("Check installed package statuses before explicitly resuming", response.details, 1, true)
        assert.is_true(response.partial)
        assert.is_true(response.resume_available)
        assert.same({ COMPAT, COMPAT }, c.installs, "a failed APK command must not automatically continue with the theme")
        assert.equal("3.0.0-r2", c.installed[COMPAT])
        assert.is_nil(c.statuses[COMPAT], "the reinstalled compatibility package itself is healthy")
        assert.equal("2.4.8-r2", c.installed[THEME])
        assert.same({ "installed", "broken-script" }, c.statuses[THEME][1].status)
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        local pending = H.json.parse(H.vfs_read(STATE))
        assert.equal("compat", pending.phase)
        assert.equal("3.0.0-r2", pending.release.version)
        assert.falsy(pending.steps[1].done)
        assert.falsy(pending.steps[2].done)
        assert.same(original_plan.original, pending.original)
        assert.equal(1, c.github_calls)
        no_finish()
        -- A fresh user-initiated call observes healthy target compat, skips its
        -- APK command, and repairs the old theme with its own new installation.
        c.install_override = function(name)
            successful_package_install(c, name)
            return exit_output("Installed " .. name)
        end
        local resumed = c.theme.update()
        assert.is_true(resumed.success, resumed.error or resumed.details)
        assert.equal("3.0.0-r2", resumed.new_version)
        assert_recovered(c, original_plan)
    end)
end)

describe("Argon native UCI export boundary", function()
    local export_errors = {
        { "nonzero native exit", function() return uci_output("package argon\n", 1) end },
        { "missing exit marker", function() return "package argon\nconfig global 'global'\n" end },
        { "malformed quoted export", function() return uci_output("package argon\nconfig global\n option mode 'unclosed\n") end },
        { "unexpected package", function() return uci_output("package other\nconfig global\n option mode 'dark'\n") end },
        { "oversized export", function() return uci_output("package argon\n" .. string.rep(" ", 1048577)) end },
        { "reader error", function() return { content = uci_output("package argon\n"), read_error = true } end }
    }

    for _, case in ipairs(export_errors) do
        it("treats " .. case[1] .. " as a failed snapshot, not an empty original", function()
            local c = begin()
            c.export_overrides["/etc/config"] = case[2]()
            local snapshot, err = c.cfg.snapshot()
            assert.is_nil(snapshot)
            assert.is_string(err)
            H.vfs_write(BACKUP, "previous verified original")
            local response = failed(c, "backup")
            assert.equal("Cannot read original Argon UCI", response.error)
            assert.matches(err, response.details, 1, true)
            assert.equal(c.original_raw, H.vfs_read(CONFIG))
            assert.equal("previous verified original", H.vfs_read(BACKUP))
            assert.same({}, c.installs)
            assert.falsy(H.vfs_exists(STATE))
            no_finish()
        end)

        it("does not apply a missing-config recovery candidate after " .. case[1], function()
            local c = begin()
            c.install_override = function(name) c.perform_install(name); c.remove_config(); return exit_output() end
            c.export_overrides[STAGING .. "/recovery"] = case[2]()
            local response = failed(c, "config")
            assert.equal("Cannot restore missing Argon configuration", response.error)
            assert.is_true(response.partial)
            assert.truthy(H.vfs_exists(RECOVERY))
            private_stages(RECOVERY)
            assert.falsy(H.vfs_exists(CONFIG))
            assert.equal(c.original_raw, H.vfs_read(BACKUP))
            private_stages()
            no_finish()
        end)
    end

    it("reports a migration-directory export error even though the unrelated LuCI RPC cursor has a global section", function()
        local c = begin()
        H.vfs_write(MIGRATION, c.original_raw)
        c.remove_config()
        c.export_overrides["/etc/argon-config-migration"] = uci_output("", 1)
        local snapshot, err = c.cfg.snapshot("/etc/argon-config-migration")
        assert.is_nil(snapshot)
        assert.matches("Cannot export native Argon UCI", err, 1, true)
        local response = failed(c, "backup")
        assert.equal("Cannot read original Argon UCI", response.error)
        assert.matches(err, response.details, 1, true)
        assert.equal(c.original_raw, H.vfs_read(MIGRATION))
        assert.same({}, c.installs)
        assert.falsy(H.vfs_exists(BACKUP))
        assert.is_true(has_command(H.popen_cmds(), "uci -q -c '/etc/argon-config-migration' -C '' -t '" .. STAGING .. "/uci' export argon"))
        no_finish()
    end)

    local function long_config()
        local config = sections("dark", true)
        config[3].quoted = "begin " .. string.rep("O'Reilly's \"double\" \\ # literal; ", 24) .. "scalar end"
        config[3].multiline = "first 'quoted' line\n" .. string.rep("long 'quoted' line; # text \\ \n", 24) .. 'last "line"'
        config[3].order = { string.rep("first's item ", 30) .. "first end", string.rep("second\napostrophe's line ", 30) .. "second end" }
        return config
    end

    it("parses complete quoted/multiline/list export values beyond 256 bytes without consulting LuCI state", function()
        local config = long_config()
        local c = begin({ config = config })
        local snapshot = c.snapshot()
        assert.is_true(snapshot[1].anonymous)
        assert.same(options(config[3]), snapshot[3].options)
        assert.is_true(#snapshot[3].options.quoted > 256)
        assert.is_true(#snapshot[3].options.multiline > 256)
        assert.is_true(#snapshot[3].options.order[1] > 256)
        assert.is_true(#snapshot[3].options.order[2] > 256)
        assert.same(options(config[3]), options(c.read_config()[3]))
        assert.equal("RPC cursor ignores confdir", H.state().uci.argon[1].future_option)
    end)

    it("retains the default short-token lexer contract while full_values returns every quoted byte", function()
        local value = long_config()[3].multiline
        local raw = "option value " .. uci_quote(value) .. "\n"
        local lib = require("podkop-tweaker.lib")
        local short = assert(lib.uci_statements(raw))
        local complete = assert(lib.uci_statements(raw, true))
        assert.equal(value:sub(1, 256), short[1].tokens[3])
        assert.equal(value, complete[1].tokens[3])
    end)

    it("validates and atomically applies a generated recovery candidate with complete long escaped values", function()
        local config = long_config()
        local c = begin({ config = config })
        local original = c.snapshot()
        c.remove_config()
        local restored, err = c.cfg.restore_missing(c.original_raw, original, true)
        assert.is_true(restored, err)
        assert.same(options(config[3]), c.snapshot()[3].options)
        assert.same(options(config[3]), options(c.read_config()[3]))
        private_stages(RECOVERY)
        private_stages(CONFIG)
        assert.equal("600", H.vfs_mode(CONFIG))
        private_stages()
        assert.is_true(has_command(H.popen_cmds(), "uci -q -c '" .. STAGING .. "/recovery' -C '' -t '" .. STAGING .. "/uci' export argon"))
        assert.same({}, H.commits(), "native missing-config repair must not commit through the shared LuCI cursor")
    end)

    it("backs up and repairs complete long quoted/multiline/list values through the validated private candidate", function()
        local config = long_config()
        local c = begin({ config = config })
        c.install_override = function(name) c.perform_install(name); c.remove_config(); return exit_output() end
        local response = c.theme.update()
        assert.is_true(response.success, (response.error or "") .. "\n" .. (response.details or ""))
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        assert.same(options(config[3]), c.snapshot()[3].options)
        assert.same(options(config[3]), options(c.read_config()[3]))
        private_stages(RECOVERY)
        private_stages(CONFIG)
        assert.equal("600", H.vfs_mode(CONFIG))
        private_stages()
        assert.is_true(has_command(H.popen_cmds(), "uci -q -c '" .. STAGING .. "/recovery' -C '' -t '" .. STAGING .. "/uci' export argon"))
    end)
end)

describe("Argon native UCI delta isolation", function()
    local delta_paths = { "/tmp/.uci/argon", STAGING .. "/uci/argon" }

    for _, case in ipairs({ { "default dark-to-light pending delta", delta_paths[1] }, { "private stale delta", delta_paths[2] } }) do
        it("stops before backup/install with a " .. case[1], function()
            local c = begin()
            local changes = "argon.global.mode='light'\n"
            H.vfs_write(case[2], changes)
            assert.equal("dark", c.read_config()[1].mode)
            local snapshot, err = c.cfg.snapshot()
            assert.is_nil(snapshot)
            assert.matches("Uncommitted Argon UCI changes", err, 1, true)
            local response = failed(c, "backup")
            assert.equal("Cannot read original Argon UCI", response.error)
            assert.matches(err, response.details, 1, true)
            assert.is_false(response.partial)
            assert.is_false(response.resume_available)
            assert.equal(c.original_raw, H.vfs_read(CONFIG))
            assert.equal(changes, H.vfs_read(case[2]))
            assert.falsy(H.vfs_exists(BACKUP))
            assert.same({}, H.stage_paths(stage_pattern(BACKUP)))
            assert.falsy(H.vfs_exists(STATE))
            assert.same({}, c.exports)
            assert.same({}, c.installs)
            no_finish()
        end)
    end

    it("allows empty default/private delta files without merging or removing them", function()
        local c = begin()
        for _, path in ipairs(delta_paths) do H.vfs_write(path, "") end
        assert.equal("dark", c.snapshot()[1].options.mode)
        local response = c.theme.update()
        assert.is_true(response.success, response.error or response.details)
        assert.equal("dark", c.snapshot()[1].options.mode)
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        for _, path in ipairs(delta_paths) do assert.equal("", H.vfs_read(path)) end
        assert.same({ THEME }, c.installs)
    end)

    for _, path in ipairs(delta_paths) do
        for _, operation in ipairs({ "open", "read", "close" }) do
            it("reports delta " .. operation .. " errors at " .. path .. " before backup/install", function()
                local c = begin({ failures = { [path] = { [operation] = true } } })
                H.vfs_write(path, "")
                local snapshot, err = c.cfg.snapshot()
                assert.is_nil(snapshot)
                local diagnostic = operation == "open" and "Injected open failure" or "Cannot inspect pending Argon UCI changes"
                assert.matches(diagnostic, err, 1, true)
                local response = failed(c, "backup")
                assert.equal("Cannot read original Argon UCI", response.error)
                assert.matches(diagnostic, response.details, 1, true)
                assert.equal(c.original_raw, H.vfs_read(CONFIG))
                assert.equal("", H.vfs_read(path))
                assert.falsy(H.vfs_exists(BACKUP))
                assert.falsy(H.vfs_exists(STATE))
                assert.same({}, c.exports)
                assert.same({}, c.installs)
                no_finish()
            end)
        end
    end

    it("validates the private candidate from the selected confdir with conf2override explicitly disabled", function()
        local c = begin()
        local conf2 = "/var/run/uci/argon"
        local override = c.write_config({ H.sec("global", "global", { mode = "light", future_option = "conf2override must not win" }) }, conf2)
        c.install_override = function(name) c.perform_install(name); c.remove_config(); return exit_output() end
        local response = c.theme.update()
        assert.is_true(response.success, response.error or response.details)
        assert.equal("dark", c.snapshot()[1].options.mode)
        assert.equal("retain this value", c.snapshot()[1].options.future_option)
        assert.equal(override, H.vfs_read(conf2))
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        local candidate_exported = false
        for _, call in ipairs(c.exports) do
            assert.matches(" -C '' ", call.command, 1, true)
            assert.is_not.equal(conf2, call.path)
            if call.path == RECOVERY then
                candidate_exported = true
                assert.equal(H.vfs_read(RECOVERY), call.raw)
                assert.equal("dark", fixture_config(call.raw)[1].mode)
            end
        end
        assert.is_true(candidate_exported)
        assert.is_true(has_command(H.popen_cmds(), "uci -q -c '" .. STAGING .. "/recovery' -C '' -t '" .. STAGING .. "/uci' export argon"))
        for _, event in ipairs(H.state().io_log) do assert.is_not.equal(conf2, event.path) end
    end)
end)

describe("Argon APK download and backup barriers", function()
    it("rejects missing assets for installed locales before downloading any package", function()
        local c = begin({ assets = { THEME }, installed = { ["base-files"] = "native-r1", [THEME] = "2.4.8-r2", [ZH] = "0" } })
        local response = failed(c, "preflight")
        assert.matches(ZH, response.error, 1, true)
        assert.same({}, c.downloaded)
        assert.same({}, c.installs)
        assert.falsy(H.vfs_exists(BACKUP))
        no_finish()
    end)

    it("does not trust an invalid GitHub asset URL during update", function()
        local c = begin()
        c.github.assets[1].browser_download_url = "https://github.com/other/repo/releases/download/v3.0.0/" .. c.github.assets[1].name
        local response = failed(c, "preflight")
        assert.matches("Invalid Argon APK asset", response.error)
        assert.same({}, c.downloaded)
        assert.same({}, c.installs)
        no_finish()
    end)

    it("fails staging creation before downloading, backing up or invoking APK", function()
        local c = begin()
        c.command_failures["mkdir -p "] = exit_output("Read-only file system", 1)
        local response = failed(c, "download")
        assert.matches("Read-only file system", response.details, 1, true)
        assert.same({}, c.downloaded)
        assert.same({}, c.installs)
        assert.falsy(H.vfs_exists(BACKUP))
        no_finish()
    end)

    for _, failure in ipairs({ "curl", "size", "digest", "mktemp", "open", "write", "close", "rename" }) do
        it("does not start ANY package command when the last locale predownload fails: " .. failure, function()
            local c = begin({ installed = { ["base-files"] = "native-r1", [THEME] = "2.4.8-r2",
                [COMPAT] = "2.4.6-r1", [ZH] = "0" } })
            local asset = c.asset_by_name[ZH]
            local path = STAGING .. "/" .. asset.name
            if failure == "curl" then c.download_failures[asset.name] = "interrupted\nPT_CURL_EXIT:28\n"
            elseif failure == "size" then c.download_failures[asset.name] = "short\nPT_CURL_EXIT:0\n"
            elseif failure == "digest" then c.hash_overrides[path] = string.rep("f", 64) .. "  " .. path .. "\n"
            else fail_stage(path, failure) end
            local response = failed(c, "download")
            assert.is_false(response.partial)
            assert.is_false(response.resume_available)
            assert.equal(3, #c.downloaded)
            assert.same({}, c.installs)
            assert.equal("2.4.8-r2", c.installed[THEME])
            assert.equal(c.original_raw, H.vfs_read(CONFIG))
            assert.falsy(H.vfs_exists(BACKUP))
            assert.falsy(H.vfs_exists(STATE))
            no_finish()
        end)
    end

    it("reuses a staged APK only after exact size and digest verification", function()
        local c = begin()
        local asset = c.asset_by_name[THEME]
        H.vfs_write(STAGING .. "/" .. asset.name, c.bytes[asset.name])
        assert.is_true(c.theme.update().success)
        assert.same({}, c.downloaded)
        assert.same({ THEME }, c.installs)
        assert.equal(STAGING .. "/" .. asset.name, c.hash_calls[1])
    end)

    it("redownloads same-size staged bytes with the wrong digest instead of installing them", function()
        local c = begin()
        local asset = c.asset_by_name[THEME]
        H.vfs_write(STAGING .. "/" .. asset.name, string.rep("x", asset.size))
        assert.is_true(c.theme.update().success)
        assert.same({ asset.name }, c.downloaded)
        assert.equal(c.bytes[asset.name], c.preconditions[1].packages[asset.name])
    end)

    for _, failure in ipairs({ "open", "read", "close" }) do
        it("does not replace a previous backup when reading the original config fails: " .. failure, function()
            local c = begin({ failures = { [CONFIG] = { [failure] = true } } })
            H.vfs_write(BACKUP, "previous recovery backup")
            failed(c, "preflight")
            assert.equal("previous recovery backup", H.vfs_read(BACKUP))
            assert.equal(c.original_raw, H.vfs_read(CONFIG))
            assert.same({}, c.installs)
            no_finish()
        end)
    end

    it("rejects oversized or syntactically invalid raw config before any package mutation", function()
        local c = begin()
        H.vfs_write(CONFIG, string.rep("x", 1048577))
        failed(c, "preflight")
        assert.same({}, c.installs)
        H.vfs_write(CONFIG, "config global 'global'\n\toption primary 'unclosed\n")
        failed(c, "backup")
        assert.same({}, c.installs)
        assert.falsy(H.vfs_exists(BACKUP))
        no_finish()
    end)

    it("rejects an empty semantic snapshot for a nonempty original raw config", function()
        local c = begin()
        c.export_overrides["/etc/config"] = "package argon\n\nPT_UCI_EXIT:0\n"
        local response = failed(c, "backup")
        assert.equal("Cannot read original Argon UCI", response.error)
        assert.same({}, c.installs)
        assert.falsy(H.vfs_exists(BACKUP))
        no_finish()
    end)

    for _, operation in ipairs({ "mktemp", "open", "write", "close", "rename", "permission", "digest" }) do
        it("checks the complete private original backup before APK: " .. operation, function()
            local c = begin()
            H.vfs_write(BACKUP, "previous recovery backup")
            if operation == "permission" then
                c.execute_override = mode_failure(BACKUP, "600")
            elseif operation == "digest" then c.hash_overrides[BACKUP] = "sha256sum failed\n"
            else
                fail_stage(BACKUP, operation, 5)
            end
            local response = failed(c, "backup")
            assert.is_false(response.partial)
            assert.is_false(response.resume_available)
            assert.same({}, c.installs)
            assert.equal(c.original_raw, H.vfs_read(CONFIG))
            if operation ~= "digest" then assert.equal("previous recovery backup", H.vfs_read(BACKUP)) end
            assert.falsy(H.vfs_exists(STATE))
            no_stages_left(BACKUP)
            no_finish()
        end)
    end

    for _, operation in ipairs({ "mktemp", "open", "write", "close", "rename", "permission" }) do
        it("requires a durable private pinned recovery plan before APK: " .. operation, function()
            local c = begin()
            if operation == "permission" then
                c.execute_override = mode_failure(STATE, "600")
            else fail_stage(STATE, operation) end
            local response = failed(c, "backup")
            assert.is_false(response.partial)
            assert.is_false(response.resume_available)
            assert.same({}, c.installs)
            assert.equal(c.original_raw, H.vfs_read(BACKUP))
            assert.equal(c.original_raw, H.vfs_read(CONFIG))
            assert.falsy(H.vfs_exists(STATE))
            no_finish()
        end)
    end
end)

describe("Argon APK checked results and manual recovery", function()
    it("does not call an unchanged installed version successful merely because APK exited zero", function()
        local c = begin()
        c.install_override = function() return exit_output("APK reported OK but did nothing") end
        local response = failed(c, "theme")
        assert.matches("does not match the update target", response.error, 1, true)
        assert.is_false(response.partial)
        assert.is_true(response.resume_available)
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        assert.equal("3.0.0-r2", H.json.parse(H.vfs_read(STATE)).release.version)
        no_finish()
    end)

    it("requires the exact target revision rather than just the target base version", function()
        local c = begin()
        c.install_override = function(name)
            c.perform_install(name)
            c.installed[name] = "3.0.0-r1"
            return exit_output("wrong revision installed")
        end
        local response = failed(c, "theme")
        assert.matches("does not match the update target", response.error, 1, true)
        assert.is_true(response.partial, "a changed package/config is partial even when its revision is not the requested target")
        assert.equal("3.0.0-r2", H.json.parse(H.vfs_read(STATE)).release.version)
        no_finish()
    end)

    it("does not accept package output without a checked exit marker even after the version changes", function()
        local c = begin()
        c.install_override = function(name) c.perform_install(name); return "APK reported OK but supplied no exit marker\n" end
        local response = failed(c, "theme")
        assert.matches("Argon package installation failed", response.error, 1, true)
        assert.is_true(response.partial)
        assert.matches("supplied no exit marker", response.details, 1, true)
        no_finish()
    end)

    for _, name in ipairs({ COMPAT, THEME }) do
        it("fails a nonzero " .. name .. " hook even when inventory reports the exact target", function()
            local c = begin({ installed = { ["base-files"] = "native-r1", [THEME] = "2.4.8-r2", [COMPAT] = "2.4.6-r1" } })
            local output = "Executing " .. name .. ".post-upgrade\n" .. string.rep("hook diagnostic\n", 600) .. "* fchdir: Not a directory\nend-of-output"
            c.install_override = function(package)
                c.perform_install(package)
                return exit_output(package == name and output or "OK", package == name and 1 or 0)
            end
            local response = failed(c, name == COMPAT and "compat" or "theme")
            assert.is_true(response.partial)
            assert.is_true(response.resume_available)
            assert.matches(output, response.details, 1, true)
            assert.matches(BACKUP, response.details, 1, true)
            assert.equal(c.target, c.installed[name])
            assert.equal(c.original_raw, H.vfs_read(BACKUP))
            assert.same(name == COMPAT and { COMPAT } or { COMPAT, THEME }, c.installs)
            no_finish()
        end)
    end

    it("retains complete dependency failure output without upgrading firmware packages or restarting", function()
        local c = begin({ target = "2.4.8-r2", installed = { ["base-files"] = "native-r1", [THEME] = "2.4.4-r1" } })
        local output = "ERROR: unable to select packages:\nucode-2026.01.16 breaks luci-theme-argon[ucode>=2026.02.27]\n" ..
            string.rep("satisfies: firewall4[ucode>=2022.03.22]\n", 100) .. "dependency-output-end"
        c.install_override = function() return exit_output(output, 1) end
        local response = failed(c, "theme")
        assert.matches(output, response.details, 1, true)
        assert.is_false(response.partial)
        assert.is_false(has_command(H.exec_cmds(), "apk upgrade"))
        assert.is_false(has_command(H.exec_cmds(), "apk add --force"))
        assert.equal(c.original_raw, H.vfs_read(CONFIG))
        assert.equal(".original-argon{}\n", H.vfs_read(CSS))
        no_finish()
    end)

    for _, case in ipairs({
        { "broken post-install hook", function(v) return { { name = THEME, version = v, status = { "installed", "broken-script" } } } end },
        { "unpacked only", function(v) return { { name = THEME, version = v, status = { "unpacked" } } } end },
        { "wrong identity", function(v) return { { name = COMPAT, version = v, status = { "installed" } } } end },
        { "wrong revision", function() return { { name = THEME, version = "3.0.0-r1", status = { "installed" } } } end },
        { "duplicate identity", function(v) return { { name = THEME, version = v, status = { "installed" } },
            { name = THEME, version = v, status = { "installed" } } } end },
        { "empty result", function() return {} end },
        { "invalid JSON", function() return "not json" end },
        { "oversized status", function() return string.rep("x", 16385) end }
    }) do
        it("does not accept target inventory without healthy native APK status: " .. case[1], function()
            local c = begin()
            c.statuses[THEME] = case[2](c.target)
            local response = failed(c, "theme")
            assert.is_true(response.partial)
            assert.is_true(response.resume_available)
            assert.equal(c.target, c.installed[THEME])
            assert.same({ THEME }, c.installs)
            assert.equal(c.original_raw, H.vfs_read(BACKUP))
            no_finish()
        end)
    end

    it("pins target, original bytes and completed steps across a failed translation and the next manual call", function()
        local c = begin({ installed = { ["base-files"] = "native-r1", [THEME] = "2.4.8-r2",
            [COMPAT] = "2.4.6-r1", [RU] = "0", [ZH] = "unknown" } })
        c.install_override = function(name)
            if name == ZH then return exit_output("locale transfer failed", 1) end
            c.perform_install(name)
            return exit_output()
        end
        local response = failed(c, "translation")
        assert.is_true(response.partial)
        local original = H.vfs_read(BACKUP)
        local plan = H.json.parse(H.vfs_read(STATE))
        assert.equal("3.0.0-r2", plan.release.version)
        assert.is_true(plan.steps[1].done)
        assert.is_true(plan.steps[2].done)
        assert.is_true(plan.steps[3].done)
        assert.falsy(plan.steps[4].done)
        c.github = release_fixture("3.1.0-r1")
        local edited = c.read_config()
        edited[3].new_user_option = "added after the partial update"
        c.write_config(edited)
        local calls = c.github_calls
        local check = c.theme.check(true)
        assert.equal("3.0.0-r2", check.current_version)
        assert.equal("3.0.0-r2", check.latest_version)
        assert.is_true(check.update_available)
        assert.is_true(check.resume_available)
        assert.equal("translation", check.phase)
        assert.equal(calls, c.github_calls)
        no_finish()
        c.install_override = nil
        local resumed = c.theme.update()
        assert.is_true(resumed.success, resumed.error or resumed.details)
        assert.equal("3.0.0-r2", resumed.new_version)
        assert.same({ COMPAT, THEME, RU, ZH, ZH }, c.installs)
        assert.equal(calls, c.github_calls)
        assert.equal(original, H.vfs_read(BACKUP))
        assert.equal(c.original_raw, original)
        assert.equal("added after the partial update", c.snapshot()[3].options.new_user_option)
        assert.falsy(H.vfs_exists(STATE))
    end)

    it("retains partial=true across a nonzero target hook and Resume with incomplete native APK status", function()
        local c = begin()
        c.install_override = function(name)
            c.perform_install(name)
            c.statuses[name] = { { name = name, version = c.target, status = { "installed", "broken-script" } } }
            return exit_output("post-install hook failed", 1)
        end
        local initial = failed(c, "theme")
        assert.is_true(initial.partial)
        local state = H.json.parse(H.vfs_read(STATE))
        assert.is_true(state.changed)
        assert.falsy(state.steps[1].done)
        c.install_override = nil
        local response = failed(c, "theme")
        assert.matches("incomplete installation", response.error, 1, true)
        assert.is_true(response.partial)
        assert.is_true(H.json.parse(H.vfs_read(STATE)).changed)
        assert.same({ THEME }, c.installs)
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        no_finish()
        c.statuses[THEME] = nil
        local resumed = c.theme.update()
        assert.is_true(resumed.success, resumed.error)
        assert.same({ THEME }, c.installs)
    end)

    for _, corrupt in ipairs({ false, true }) do
        it("refuses recovery with " .. (corrupt and "changed" or "missing") .. " original backup", function()
            local c = begin()
            c.install_override = function() return exit_output("temporary package failure", 1) end
            failed(c, "theme")
            local pinned = H.vfs_read(STATE)
            if corrupt then H.vfs_write(BACKUP, "unrelated backup") else os.remove(BACKUP) end
            local response = failed(c, "preflight")
            assert.matches("backup", response.error:lower(), 1, true)
            assert.same({ THEME }, c.installs)
            assert.truthy(pinned)
            assert.truthy(H.vfs_read(STATE))
            no_finish()
        end)
    end

    it("does not replace malformed recovery state or its original backup", function()
        local c = begin()
        H.vfs_write(STATE, '{"schema":1,"release":{"version":"99.0.0-r1"}}')
        H.vfs_write(BACKUP, "important original backup")
        local raw = H.vfs_read(STATE)
        local response = failed(c, "preflight")
        assert.matches("Invalid Argon recovery state", response.error, 1, true)
        assert.equal(raw, H.vfs_read(STATE))
        assert.equal("important original backup", H.vfs_read(BACKUP))
        assert.same({}, c.installs)
        assert.equal(0, c.github_calls)
        no_finish()
    end)

    it("does not overwrite a completed recovery package that changed out of band", function()
        local c = begin({ installed = { ["base-files"] = "native-r1", [THEME] = "2.4.8-r2", [RU] = "0" } })
        c.install_override = function(name)
            if name == RU then return exit_output("try manually later", 1) end
            c.perform_install(name)
            return exit_output()
        end
        failed(c, "translation")
        c.installed[THEME] = "3.0.0-r3"
        local response = failed(c, "theme")
        assert.matches("changed during Argon recovery", response.error, 1, true)
        assert.same({ THEME, RU }, c.installs)
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        no_finish()
    end)

    it("keeps the original plan if persisting a completed package fails and can resume after IO repair", function()
        local c = begin()
        c.install_override = function(name)
            c.perform_install(name)
            fail_stage(STATE, "close")
            return exit_output()
        end
        local response = failed(c, "theme")
        assert.matches("Cannot record completed Argon package", response.error, 1, true)
        assert.matches("Cannot record recovery state", response.details, 1, true)
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        assert.equal("3.0.0-r2", H.json.parse(H.vfs_read(STATE)).release.version)
        no_finish()
        H.state().failures[stage_pattern(STATE)] = nil
        c.install_override = nil
        assert.is_true(c.theme.update().success)
        assert.same({ THEME }, c.installs)
    end)
end)

describe("Argon APK post-package failures", function()
    for _, case in ipairs({
        { "global mode", function(config) config[1].mode = "light" end, "global.mode" },
        { "unknown option", function(config) config[1].future_option = nil end, "global.future_option" },
        { "typography", function(config) config[2].font_size = "16" end, "typography.font_size" },
        { "unknown section", function(config) table.remove(config, 3) end, "unknown_plugin" },
        { "list order", function(config) config[3].order = { "second", "first", "third" } end, "unknown_plugin.order" },
        { "Bing migration", function(config) config[1].bing_background = "1" end, "Bing setting migration" }
    }) do
        it("detects a package hook that loses " .. case[1] .. " without overwriting the conflicting result", function()
            local c = begin()
            local after
            c.install_override = function(name)
                c.perform_install(name)
                local config = c.read_config()
                case[2](config)
                after = c.write_config(config)
                return exit_output()
            end
            local response = failed(c, "config")
            assert.is_true(response.partial)
            assert.is_true(response.resume_available)
            assert.equal("Argon configuration verification failed", response.error)
            assert.matches(case[3], response.details, 1, true)
            assert.equal(after, H.vfs_read(CONFIG))
            assert.equal(c.original_raw, H.vfs_read(BACKUP))
            assert.equal("config", H.json.parse(H.vfs_read(STATE)).phase)
            no_finish()
        end)
    end

    for _, operation in ipairs({ "read", "close" }) do
        it("does not proceed to CSS when rereading the original backup fails: " .. operation, function()
            local c = begin()
            c.install_override = function(name)
                c.perform_install(name)
                H.state().failures[BACKUP] = { [operation] = true }
                return exit_output()
            end
            local response = failed(c, "config")
            assert.equal("Cannot read saved Argon configuration", response.error)
            assert.equal(".new-argon-package{}\n", H.vfs_read(CSS))
            assert.equal(c.original_raw, H.vfs_read(BACKUP))
            no_finish()
        end)
    end

    for _, stage in ipairs({ { "private candidate", RECOVERY }, { "live candidate apply", CONFIG } }) do
        for _, operation in ipairs({ "mktemp", "open", "write", "close", "rename", "permission" }) do
            it("reports missing-conffile " .. stage[1] .. " " .. operation .. " failure before CSS/restart", function()
                local c = begin()
                c.install_override = function(name)
                    c.perform_install(name)
                    c.remove_config()
                    if operation == "permission" then
                        c.execute_override = mode_failure(stage[2], "600")
                    else fail_stage(stage[2], operation) end
                    return exit_output()
                end
                local response = failed(c, "config")
                assert.equal("Cannot restore missing Argon configuration", response.error)
                assert.equal(c.original_raw, H.vfs_read(BACKUP))
                assert.falsy(H.vfs_exists(CONFIG))
                assert.equal(".new-argon-package{}\n", H.vfs_read(CSS))
                no_finish()
            end)
        end
    end

    it("checks private recovery directory creation before staging a missing-config repair", function()
        local c = begin()
        c.install_override = function(name) c.perform_install(name); c.remove_config(); return exit_output() end
        c.execute_override = function(command)
            if command:find("umask 077; mkdir -p " .. STAGING .. "/recovery", 1, true) then return 1 end
        end
        local response = failed(c, "config")
        assert.matches("Cannot create private Argon recovery directory", response.details, 1, true)
        assert.falsy(H.vfs_exists(RECOVERY))
        assert.falsy(H.vfs_exists(CONFIG))
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        no_finish()
    end)

    for _, operation in ipairs({ "mktemp", "open", "write", "close", "rename", "permission" }) do
        it("retains the live theme CSS and recovery plan on atomic typography " .. operation .. " failure", function()
            local c = begin()
            if operation == "permission" then
                c.execute_override = mode_failure(CSS, "644", ".pt-typography")
            else fail_stage(CSS, operation, 5, ".pt-typography") end
            local response = failed(c, "css")
            assert.equal("Cannot restore Argon typography CSS", response.error)
            assert.is_true(response.partial)
            assert.is_true(response.resume_available)
            assert.equal(".new-argon-package{}\n", H.vfs_read(CSS))
            no_stages_left(CSS, ".pt-typography")
            assert.equal(c.original_raw, H.vfs_read(BACKUP))
            assert.equal("css", H.json.parse(H.vfs_read(STATE)).phase)
            no_finish()
        end)
    end

    it("does not replace incomplete typography markers or claim a successful update", function()
        local c = begin()
        local broken = ".theme{}\n/* === Podkop Tweaker Typography === */\nmissing end marker\n"
        c.install_override = function(name)
            c.perform_install(name)
            H.vfs_write(CSS, broken)
            return exit_output()
        end
        local response = failed(c, "css")
        assert.matches("Incomplete or duplicate Argon typography CSS markers", response.details, 1, true)
        assert.equal(broken, H.vfs_read(CSS))
        no_finish()
    end)

    for _, case in ipairs({
        { "RPC reload", "/etc/init.d/rpcd reload", "rpcd" },
        { "LuCI cache cleanup", "rm -rf /tmp/luci-", "cache" },
        { "package staging cleanup", "rm -rf " .. STAGING, "cleanup" }
    }) do
        it("keeps a resumable pinned plan after failed " .. case[1] .. " and retries only the finishing stages", function()
            local c = begin()
            local output = "permission denied\n" .. string.rep("full stage diagnostic\n", 30) .. "output-end"
            c.command_failures[case[2]] = exit_output(output, 1)
            local response = failed(c, case[3])
            assert.is_true(response.partial)
            assert.is_true(response.resume_available)
            assert.matches(output, response.details, 1, true)
            assert.equal(c.original_raw, H.vfs_read(BACKUP))
            assert.equal(case[3], H.json.parse(H.vfs_read(STATE)).phase)
            c.command_failures[case[2]] = nil
            c.github = release_fixture("3.1.0-r1")
            local calls = c.github_calls
            assert.is_true(c.theme.update().success)
            assert.same({ THEME }, c.installs)
            assert.equal(calls, c.github_calls)
            assert.equal(c.original_raw, H.vfs_read(BACKUP))
            assert.falsy(H.vfs_exists(STATE))
        end)
    end

    it("does not finish when release-cache removal fails", function()
        local c = begin()
        local remove = os.remove
        os.remove = function(path) if path == CACHE then return nil, "Injected cache unlink failure" end; return remove(path) end
        local response = failed(c, "cache")
        assert.equal("Cannot remove Argon release cache", response.error)
        assert.truthy(H.vfs_exists(CACHE))
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        assert.truthy(H.vfs_exists(STATE))
    end)

    it("does not finish or restart when final recovery-state removal fails", function()
        local c = begin()
        local remove = os.remove
        os.remove = function(path) if path == STATE then return nil, "Injected state unlink failure" end; return remove(path) end
        local response = failed(c, "cleanup")
        assert.equal("Cannot finish Argon recovery state", response.error)
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        assert.equal("cleanup", H.json.parse(H.vfs_read(STATE)).phase)
        assert.is_true(c.theme.check().resume_available)
    end)
end)

describe("Argon APK restart evidence", function()
    local function new_process()
        H.vfs_write("/proc/100/stat", "100 (uhttpd) S " .. string.rep("0 ", 18) .. "2000\n")
    end

    it("confirms readiness only after full success, a new process and the exact full APK revision", function()
        local c = begin()
        local updates = require("podkop-tweaker.api_update")
        local response = c.theme.update(ID)
        assert.is_true(response.success, response.error)
        assert.equal(ID, response.restart_id)
        local record = H.json.parse(H.vfs_read(RECORD))
        assert.equal("applied", record.state)
        assert.equal("3.0.0-r2", record.expected_version)
        assert.is_false(updates.restart_status(ID).ready)
        new_process()
        assert.is_true(updates.restart_status(ID).ready)
        c.installed[THEME] = "3.0.0-r1"
        assert.is_false(updates.restart_status(ID).ready)
    end)

    it("cannot promote a failed hook into readiness using a changed version and process", function()
        local c = begin()
        c.install_override = function(name) c.perform_install(name); return exit_output("post-install failed", 1) end
        local response = c.theme.update(ID)
        assert.is_false(response.success)
        assert.is_true(response.partial)
        assert.equal(c.target, c.installed[THEME])
        local updates = require("podkop-tweaker.api_update")
        new_process()
        local status = updates.restart_status(ID)
        assert.truthy(status.error, "a failed theme job writes no restart evidence")
        no_finish()
    end)

    it("does not report readiness after a finishing-stage failure even if all package versions match", function()
        local c = begin()
        c.command_failures["/etc/init.d/rpcd reload"] = exit_output("rpcd reload failed", 1)
        local response = c.theme.update(ID)
        assert.is_false(response.success)
        assert.equal("rpcd", response.phase)
        new_process()
        assert.truthy(require("podkop-tweaker.api_update").restart_status(ID).error,
            "a failed theme job writes no restart evidence")
        no_restart()
    end)

    it("keeps an applied pipeline distinct from a failed restart schedule", function()
        local c = begin()
        c.execute_override = function(command) if command:find("uhttpd restart", 1, true) then return 1 end end
        local response = c.theme.update(ID)
        assert.is_true(response.success)
        assert.equal("3.0.0-r2", response.new_version)
        assert.falsy(H.vfs_exists(STATE))
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        local job = H.json.parse(H.vfs_read("/tmp/pt-argon-theme-job.json"))
        assert.equal("completed", job.state)
        assert.is_false(job.restart.queued)
        assert.matches("web restart could not be scheduled", job.restart.error, 1, true)
        new_process()
        local status = require("podkop-tweaker.api_update").restart_status(ID)
        assert.equal("failed", status.state)
        assert.is_false(status.ready)
    end)

    it("holds web-update during package downloads and excludes a competing legacy cache mutation", function()
        local c = begin()
        local competing, mutations
        mutations = 0
        c.on_download = function()
            c.on_download = nil
            assert.truthy(H.vfs_exists(WEB_LOCK))
            local job = coroutine.create(function()
                competing = require("podkop-tweaker.web_restart").run(nil, "cache", function()
                    mutations = mutations + 1
                    return { success = true }
                end)
            end)
            local resumed, err = coroutine.resume(job)
            assert.is_true(resumed, err)
            assert.equal("dead", coroutine.status(job))
        end
        local response = c.theme.update(ID)
        assert.is_true(response.success, response.error or response.details)
        assert.truthy(competing.error)
        assert.falsy(competing.applied)
        assert.equal(0, mutations)
        assert.same({ THEME }, c.installs)
        assert.equal(ID, H.json.parse(H.vfs_read(RECORD)).id)
        assert.falsy(H.vfs_exists(WEB_LOCK))
    end)

    it("refuses an existing web-update lock before inventory/downloads or recovery publication", function()
        local c = begin()
        H.vfs_mkdir(WEB_LOCK)
        H.vfs_write(WEB_LOCK .. "/owner", "other invocation")
        local response = c.theme.update(ID)
        assert.is_false(response.success)
        assert.truthy(response.error)
        assert.falsy(response.applied)
        assert.equal(0, c.github_calls)
        assert.same({}, c.downloaded)
        assert.same({}, c.installs)
        assert.falsy(H.vfs_exists(BACKUP))
        assert.falsy(H.vfs_exists(STATE))
        assert.falsy(H.vfs_exists(RECORD))
        assert.equal(c.original_raw, H.vfs_read(CONFIG))
        assert.equal("other invocation", H.vfs_read(WEB_LOCK .. "/owner"))
        assert.truthy(H.vfs_exists(WEB_LOCK))
        no_finish()
    end)

    it("keeps checked theme readiness read-only after an applied lock-release failure", function()
        local c = begin({ failures = { [WEB_LOCK] = { rmdir = true } } })
        local response = c.theme.update(ID)
        assert.is_true(response.success)
        assert.equal("3.0.0-r2", response.new_version)
        assert.falsy(H.vfs_exists(STATE))
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        assert.truthy(H.vfs_exists(WEB_LOCK))
        local updates = require("podkop-tweaker.api_update")
        assert.is_false(updates.restart_status(ID).ready)
        new_process()
        assert.is_true(updates.restart_status(ID).ready)
        c.installed[THEME] = "3.0.0-r1"
        assert.is_false(updates.restart_status(ID).ready)
        local calls = c.github_calls
        assert.truthy(c.theme.update(string.rep("b", 32)).error)
        assert.same({ THEME }, c.installs)
        assert.equal(calls, c.github_calls)
        assert.truthy(H.vfs_exists(WEB_LOCK))
    end)

    it("publishes only owned unique private recovery/CSS/evidence stages and leaves old fixed temporaries intact", function()
        local c = begin()
        local fixed = { BACKUP .. ".tmp-write", STATE .. ".tmp-write", RECOVERY .. ".tmp-write",
            CONFIG .. ".tmp-write", CSS .. ".pt-typography", RECORD .. ".tmp-write" }
        for _, path in ipairs(fixed) do H.vfs_write(path, "foreign stage: " .. path) end
        c.install_override = function(name) c.perform_install(name); c.remove_config(); return exit_output() end
        local response = c.theme.update(ID)
        assert.is_true(response.success, response.error or response.details)
        for _, path in ipairs(fixed) do assert.equal("foreign stage: " .. path, H.vfs_read(path)) end
        for _, target in ipairs({ BACKUP, STATE, RECOVERY, CONFIG, RECORD }) do
            private_stages(target)
            no_stages_left(target)
        end
        private_stages(CSS, ".pt-typography")
        no_stages_left(CSS, ".pt-typography")
        assert.equal("600", H.vfs_mode(BACKUP))
        assert.equal("600", H.vfs_mode(RECORD))
        assert.equal("600", H.vfs_mode(CONFIG))
        assert.matches("font-size: 17px", H.vfs_read(CSS), 1, true)
    end)
end)

describe("Argon APK metadata and package plan", function()
    local function pkg() H.begin(); return require("podkop-tweaker.theme_packages") end

    it("compares complete canonical package revisions numerically", function()
        local p = pkg()
        assert.same({ 2, 4, 8, 2 }, p.version("2.4.8-r2"))
        assert.equal(-1, p.compare("2.4.8-r2", "2.4.8-r10"))
        assert.equal(0, p.compare("3.0.0-r2", "3.0.0-r2"))
        assert.equal(1, p.compare("3.0.0-r1", "2.4.8-r99"))
        for _, value in ipairs({ "2.4.8", "v2.4.8-r2", "2.4.8-r02", "02.4.8-r2", "2.4.8-r2;id", "2.4.8-r-1", "2.4.8-r1000000" }) do
            assert.is_nil(p.version(value), value)
        end
    end)

    it("reads native manifest names including hyphen locales and legacy locale version sentinels", function()
        local p = pkg()
        local expected = { [THEME] = "2.4.8-r2", [COMPAT] = "2.4.6-r1", [ZH] = "0", [RU] = "unknown", ["base-files"] = "1666~native-r1" }
        assert.same(expected, p.inventory(manifest(expected) .. "luci-i18n-base-ru 26.1-r1\nunrelated 1.0-r1\n"))
        assert.is_nil(p.inventory(manifest(expected) .. THEME .. " 2.4.8-r1\n"))
        assert.is_nil(p.inventory(string.rep("x", 262145)))
    end)

    it("selects the highest complete theme revision and does not substitute IPK or mismatched locale revisions", function()
        local p = pkg()
        local release = release_fixture("2.4.8-r2", { THEME, ZH })
        local old = release_fixture("2.4.8-r1", { THEME, RU })
        for _, asset in ipairs(old.assets) do release.assets[#release.assets + 1] = asset end
        release.assets[#release.assets + 1] = { name = "luci-theme-argon_2.4.8_all.ipk", browser_download_url = "https://example.invalid/theme.ipk" }
        local target = assert(p.release(release))
        assert.equal("2.4.8-r2", target.version)
        assert.truthy(target.packages[ZH])
        assert.is_nil(target.packages[RU])
        assert.is_true(p.valid_release(target))
        local steps, err = p.plan(target, { [THEME] = "2.4.8-r1", [RU] = "0" })
        assert.is_nil(steps)
        assert.matches(RU, err, 1, true)
    end)

    for _, case in ipairs({
        { "HTTP", function(a) a.browser_download_url = a.browser_download_url:gsub("https:", "http:") end },
        { "foreign owner", function(a) a.browser_download_url = a.browser_download_url:gsub("jerrykuku", "someone") end },
        { "foreign repository", function(a) a.browser_download_url = a.browser_download_url:gsub("/luci%-theme%-argon/", "/other/") end },
        { "query suffix", function(a) a.browser_download_url = a.browser_download_url .. "?redirect=1" end },
        { "encoded path", function(a) a.browser_download_url = a.browser_download_url:gsub("/v3.0.0/", "/%%763.0.0/") end },
        { "wrong filename URL", function(a) a.browser_download_url = a.browser_download_url .. ".other" end },
        { "missing size", function(a) a.size = nil end },
        { "zero size", function(a) a.size = 0 end },
        { "fractional size", function(a) a.size = 3.5 end },
        { "oversize APK", function(a) a.size = 2097153 end },
        { "missing digest", function(a) a.digest = nil end },
        { "short digest", function(a) a.digest = "sha256:" .. string.rep("a", 63) end },
        { "uppercase digest", function(a) a.digest = "sha256:" .. string.rep("A", 64) end },
        { "wrong digest algorithm", function(a) a.digest = "sha512:" .. string.rep("a", 64) end }
    }) do
        it("rejects " .. case[1] .. " release assets before constructing an install plan", function()
            local p = pkg()
            local release = release_fixture()
            case[2](release.assets[1])
            local target, err = p.release(release)
            assert.is_nil(target)
            assert.matches("Invalid Argon APK asset", err)
        end)
    end

    it("rejects unstable, noncanonical, duplicate and APK-free release metadata", function()
        local p = pkg()
        for _, change in ipairs({
            function(r) r.prerelease = true end,
            function(r) r.draft = true end,
            function(r) r.tag_name = "v03.0.0" end,
            function(r) r.tag_name = "v3.0.0/../v3.0.0" end,
            function(r) r.assets[2] = copy(r.assets[1]) end,
            function(r) r.assets = { { name = "luci-theme-argon_3.0.0_all.ipk" } } end
        }) do
            local release = release_fixture()
            change(release)
            assert.is_nil(p.release(release))
        end
    end)

    for _, source in ipairs({ "2.4.4-r1", "2.4.8-r2" }) do
        it("plans the separate legacy config handoff before theme from " .. source, function()
            local p = pkg()
            local target = assert(p.release(release_fixture()))
            local steps = assert(p.plan(target, { [THEME] = source, [COMPAT] = "2.4.6-r1", [ZH] = "0", [RU] = "unknown" }))
            assert.same({ { name = COMPAT, phase = "compat" }, { name = THEME, phase = "theme" },
                { name = RU, phase = "translation" }, { name = ZH, phase = "translation" } }, steps)
        end)
    end

    it("never installs a legacy config package or translations that are not installed", function()
        local p = pkg()
        assert.same({ { name = THEME, phase = "theme" } }, p.plan(p.release(release_fixture()), { [THEME] = "2.4.8-r2" }))
    end)

    it("plans same-base revision and translation-only updates using full installed versions", function()
        local p = pkg()
        local target = p.release(release_fixture("2.4.8-r2"))
        assert.same({ { name = THEME, phase = "theme" }, { name = ZH, phase = "translation" } },
            p.plan(target, { [THEME] = "2.4.8-r1", [ZH] = "2.4.8-r1" }))
        assert.same({ { name = RU, phase = "translation" } }, p.plan(target, { [THEME] = "2.4.8-r2", [RU] = "0" }))
        assert.same({}, p.plan(target, { [THEME] = "2.4.8-r2", [RU] = "2.4.8-r2" }))
    end)

    it("refuses incomplete compatibility/locale asset sets, unsupported versions and theme downgrades", function()
        local p = pkg()
        local target = p.release(release_fixture("3.0.0-r2", { THEME }))
        assert.is_nil(p.plan(target, { [THEME] = "2.4.8-r2", [COMPAT] = "2.4.6-r1" }))
        assert.is_nil(p.plan(target, { [THEME] = "2.4.8-r2", [ZH] = "0" }))
        assert.is_nil(p.plan(target, { [THEME] = "2.4.8-r2", [COMPAT] = "unknown" }))
        assert.is_nil(p.plan(target, { [THEME] = "2.4.8-r2", [RU] = "rolling" }))
        assert.is_nil(p.plan(target, { [THEME] = "2.4.3-r99" }))
        assert.is_nil(p.plan(target, { [THEME] = "3.0.0-r3" }))
    end)
end)

describe("Argon native APK environment and live checks", function()
    it("reports the complete installed revision and never consults opkg", function()
        local c = begin()
        assert.equal("2.4.8-r2", c.theme.installed_version())
        assert.same({ MANIFEST }, H.exec_cmds())
        c.installed[THEME] = nil
        assert.is_nil(c.theme.installed_version())
        assert.is_false(c.theme.check().update_available)
        assert.equal(0, c.github_calls)
        assert.is_false(has_command(H.exec_cmds(), "opkg"))
    end)

    for _, case in ipairs({
        { "OpenWrt 25.12.3", { openwrt = "25.12.3" }, "OpenWrt 25.12.4" },
        { "older OpenWrt", { openwrt = "24.10.4" }, "OpenWrt 25.12.4" },
        { "unidentified snapshot", { openwrt = "SNAPSHOT" }, "OpenWrt 25.12.4" },
        { "APK 2", { apk_version = "apk-tools 2.14.4, compiled for aarch64.\n" }, "apk-tools 3.x" },
        { "missing native base-files", { installed = { [THEME] = "2.4.8-r2" } }, "Native OpenWrt APK" },
        { "Argon below the floor", { installed = { ["base-files"] = "native-r1", [THEME] = "2.4.3-r99" } }, "Argon 2.4.4" }
    }) do
        it("rejects " .. case[1] .. " before downloads, backup or package commands", function()
            local c = begin(case[2])
            local response = failed(c, "preflight")
            assert.matches(case[3], response.error, 1, true)
            assert.equal(0, c.github_calls)
            assert.same({}, c.installs)
            assert.falsy(H.vfs_exists(BACKUP))
            assert.falsy(H.vfs_exists(STATE))
            no_finish()
        end)
    end

    it("caches release metadata but rereads installed theme and translation revisions on every check", function()
        local c = begin()
        c.cache()
        assert.is_true(c.theme.check().update_available)
        c.installed[THEME] = c.target
        local current = c.theme.check()
        assert.equal("3.0.0-r2", current.current_version)
        assert.equal("3.0.0-r2", current.latest_version)
        assert.is_false(current.update_available)
        c.installed[ZH] = "0"
        assert.is_true(c.theme.check().update_available)
        c.installed[ZH] = c.target
        assert.is_false(c.theme.check().update_available)
        assert.equal(0, c.github_calls)
        assert.is_nil(current.download_url_ipk)
        assert.equal(c.asset_by_name[THEME].browser_download_url, current.download_url_apk)
    end)

    for _, age in ipairs({ 86400, 90000, -60 }) do
        it("refetches release cache with invalid age " .. age, function()
            local c = begin()
            c.cache(age)
            assert.is_true(c.theme.check().update_available)
            assert.equal(1, c.github_calls)
            local cached = H.json.parse(H.vfs_read(CACHE))
            assert.equal(2, cached.schema)
            assert.is_nil(cached.current_version)
            assert.equal(c.target, cached.release.version)
        end)
    end

    it("bypasses a fresh cache explicitly and surfaces API rate limiting", function()
        local c = begin()
        c.cache()
        c.github_raw = '{"message":"API rate limit exceeded"}'
        local response = c.theme.check(true)
        assert.equal("GitHub API rate limit exceeded", response.error)
        assert.is_false(response.update_available)
        assert.equal(1, c.github_calls)
        assert.same({}, c.installs)
    end)

    it("discards old decision caches and unsafe cached asset metadata", function()
        local c = begin()
        H.vfs_write(CACHE, H.json.stringify({ current_version = "0.0.0", latest_version = "99.0.0", update_available = true, cached_at = os.time() }))
        assert.equal(c.target, c.theme.check().latest_version)
        local cached = H.json.parse(H.vfs_read(CACHE))
        cached.release.packages[THEME].url = "https://example.invalid/foreign.apk"
        H.vfs_write(CACHE, H.json.stringify(cached))
        assert.equal(c.asset_by_name[THEME].browser_download_url, c.theme.check().download_url_apk)
        assert.equal(2, c.github_calls)
        assert.same({}, c.installs)
    end)

    it("fails an equal-version no-op without backing up or queuing a restart", function()
        local c = begin({ target = "2.4.8-r2" })
        local response = failed(c, "preflight")
        assert.matches("already up to date", response.error, 1, true)
        assert.same({}, c.installs)
        assert.falsy(H.vfs_exists(BACKUP))
        no_finish()
    end)
end)

describe("Argon APK staged installation and preservation", function()
    for _, source in ipairs({ "2.4.4-r1", "2.4.8-r2" }) do
        it("upgrades " .. source .. " plus legacy config 2.4.6-r1 using independent checked package commands", function()
            local c = begin({ installed = { ["base-files"] = "native-r1", [THEME] = source,
                [COMPAT] = "2.4.6-r1", [RU] = "unknown", [ZH] = "0" }, anonymous = true })
            local response = c.theme.update()
            assert.is_true(response.success, response.error or response.details)
            assert.equal("3.0.0-r2", response.new_version)
            assert.same({ COMPAT, THEME, RU, ZH }, c.installs)
            assert.equal(4, #c.downloaded)
            local first = c.preconditions[1]
            assert.equal(c.original_raw, first.backup)
            assert.equal("3.0.0-r2", first.state.release.version)
            assert.equal(checksum(c.original_raw), first.state.backup_sha256)
            assert.equal(3, #first.state.original)
            assert.equal("dark", first.state.original[1].options.mode)
            assert.equal("17", first.state.original[2].options.font_size)
            assert.same({ "first", "second", "third" }, first.state.original[3].options.order)
            private_stages(BACKUP)
            private_stages(STATE)
            assert.equal("600", H.vfs_mode(BACKUP))
            assert.equal("600", first.backup_mode)
            assert.equal("600", first.state_mode)
            private_stages()
            for _, name in ipairs({ COMPAT, THEME, RU, ZH }) do
                local asset = c.asset_by_name[name]
                assert.equal(c.bytes[asset.name], first.packages[asset.name], "package not predownloaded: " .. name)
                assert.is_true(has_command(first.hashes, STAGING .. "/" .. asset.name), "APK digest not checked before package commands: " .. name)
                assert.is_true(has_command(H.exec_cmds(), "(cd / && apk add --allow-untrusted '" .. STAGING .. "/" .. asset.name .. "')"))
                assert.is_true(has_command(H.exec_cmds(), "apk query --from installed --installed --fields name,version,status --format json --match name '" .. name .. "'"))
                assert.equal(c.target, c.installed[name])
            end
            assert.is_nil(first.packages[c.asset_by_name[DE].name])
            assert.equal(c.original_raw, H.vfs_read(BACKUP))
            assert.falsy(H.vfs_exists(STATE))
            assert.falsy(H.vfs_exists(CACHE))
            local config = c.snapshot()
            assert.equal("dark", config[1].options.mode)
            assert.equal("#abcdef", config[1].options.primary)
            assert.equal("#123456", config[1].options.dark_primary)
            assert.equal("custom", config[1].options.dark_primary_mode)
            assert.equal("custom", config[1].options.dark_glass_mode)
            assert.equal("bing", config[1].options.online_wallpaper)
            assert.is_nil(config[1].options.bing_background)
            assert.equal("retain this value", config[1].options.future_option)
            assert.same(options(c.original_sections[2]), config[2].options)
            assert.same(options(c.original_sections[3]), config[3].options)
            local css = H.vfs_read(CSS)
            assert.matches("new-argon-package", css, 1, true)
            assert.matches("font-size: 17px", css, 1, true)
            assert.matches("font-weight: 550", css, 1, true)
            assert.is_true(has_command(H.exec_cmds(), "/etc/init.d/rpcd reload"))
            assert.is_true(has_command(H.exec_cmds(), "rm -rf /tmp/luci-"))
            assert.is_true(has_command(H.execute_cmds(), "sleep 1; /etc/init.d/uhttpd restart"))
            assert.is_false(has_command(H.exec_cmds(), "apk upgrade"))
            assert.is_false(has_command(H.exec_cmds(), "opkg"))
        end)
    end

    it("does not introduce uninstalled compatibility or locale packages", function()
        local c = begin()
        assert.is_true(c.theme.update().success)
        assert.same({ THEME }, c.installs)
        assert.same({ c.asset_by_name[THEME].name }, c.downloaded)
        assert.is_nil(c.installed[COMPAT])
        assert.is_nil(c.installed[RU])
        assert.is_nil(c.installed[ZH])
    end)

    it("upgrades r1 to r2 without stripping revisions or migrating a 2.x config", function()
        local c = begin({ target = "2.4.8-r2", installed = { ["base-files"] = "native-r1", [THEME] = "2.4.8-r1", [ZH] = "0" } })
        local response = c.theme.update()
        assert.is_true(response.success, response.error)
        assert.equal("2.4.8-r2", response.new_version)
        assert.same({ THEME, ZH }, c.installs)
        assert.equal(c.original_raw, H.vfs_read(CONFIG))
        assert.equal("1", c.snapshot()[1].options.bing_background)
    end)

    it("updates only an installed locale with an already-target theme and a sparse valid global, without migration/default requirements", function()
        local c = begin({ installed = { ["base-files"] = "native-r1", [THEME] = "3.0.0-r2", [RU] = "unknown" },
            config = { H.sec("global", "global", { mode = "dark", future_option = "sparse user settings" }) } })
        assert.is_true(c.theme.check().update_available)
        local response = c.theme.update()
        assert.is_true(response.success, response.error)
        assert.same({ RU }, c.installs)
        assert.equal("3.0.0-r2", c.theme.installed_version())
        assert.equal(c.original_raw, H.vfs_read(CONFIG))
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        assert.same({ mode = "dark", future_option = "sparse user settings" }, c.snapshot()[1].options)
        assert.equal(".original-argon{}\n", H.vfs_read(CSS))
    end)

    for _, mode in ipairs({ "normal", "dark", "light" }) do
        it("preserves " .. mode .. " mode and explicit migration choices in an anonymous global section", function()
            local config = sections(mode, true)
            config[1].dark_primary_mode, config[1].dark_glass_mode = "auto", "inherit"
            config[1].online_wallpaper = "unsplash"
            local c = begin({ config = config })
            assert.is_true(c.theme.update().success)
            local current = c.snapshot()[1].options
            assert.equal(mode, current.mode)
            assert.equal("auto", current.dark_primary_mode)
            assert.equal("inherit", current.dark_glass_mode)
            assert.equal("unsplash", current.online_wallpaper)
            assert.is_nil(current.bing_background)
        end)
    end

    it("migrates disabled Bing and inherited dark settings without inventing custom modes", function()
        local config = sections()
        local global = config[1]
        global.bing_background, global.dark_primary, global.blur_dark, global.transparency_dark = "0", nil, nil, nil
        local c = begin({ config = config })
        assert.is_true(c.theme.update().success)
        local current = c.snapshot()[1].options
        assert.equal("none", current.online_wallpaper)
        assert.equal("auto", current.dark_primary_mode)
        assert.equal("inherit", current.dark_glass_mode)
    end)

    for _, key in ipairs({ "blur_dark", "transparency_dark" }) do
        it("uses POSIX empty-value fallback for " .. key .. " while preserving the original empty option", function()
            local config = sections()
            config[1].blur_dark, config[1].transparency_dark = config[1].blur, config[1].transparency
            config[1][key] = ""
            local c = begin({ config = config })
            local response = c.theme.update()
            assert.is_true(response.success, response.error or response.details)
            local current = c.snapshot()[1].options
            assert.equal("inherit", current.dark_glass_mode)
            assert.equal("", current[key])
            assert.equal("", c.read_config()[1][key])
            assert.equal(c.original_raw, H.vfs_read(BACKUP))
        end)
    end

    it("repairs a missing config whose original has no bing_background without creating a false/nil option", function()
        local config = sections()
        config[1].bing_background = nil
        local c = begin({ config = config })
        c.install_override = function(name) c.perform_install(name); c.remove_config(); return exit_output() end
        local response = c.theme.update()
        assert.is_true(response.success, response.error or response.details)
        local current = c.snapshot()
        assert.is_nil(current[1].options.bing_background)
        assert.is_nil(c.read_config()[1].bing_background)
        assert.equal("none", current[1].options.online_wallpaper)
        assert.same(options(config[2]), current[2].options)
        assert.same(options(config[3]), current[3].options)
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        private_stages(RECOVERY)
        private_stages()
    end)

    it("restores a raw unchanged legacy conffile removed by the package handoff, including unknown sections and lists", function()
        local c = begin({ installed = { ["base-files"] = "native-r1", [THEME] = "2.4.4-r1", [COMPAT] = "2.4.6-r1" } })
        c.install_override = function(name)
            c.perform_install(name)
            if name == THEME then c.remove_config() end
            return exit_output()
        end
        local response = c.theme.update()
        assert.is_true(response.success, response.error or response.details)
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        assert.truthy(H.vfs_read(CONFIG))
        local restored = c.snapshot()
        assert.equal("bing", restored[1].options.online_wallpaper)
        assert.same(options(c.original_sections[2]), restored[2].options)
        assert.same(options(c.original_sections[3]), restored[3].options)
        assert.is_false(has_command(H.exec_cmds(), "uci import"))
    end)

    it("reads a migration-only config using native CLI confdir despite the shared LuCI RPC cursor", function()
        local c = begin()
        H.vfs_write(MIGRATION, c.original_raw)
        c.remove_config()
        local response = c.theme.update()
        assert.is_true(response.success, response.error or response.details)
        assert.equal(c.original_raw, H.vfs_read(BACKUP))
        assert.same(options(c.original_sections[3]), c.snapshot()[3].options)
        assert.equal("RPC cursor ignores confdir", require("luci.model.uci").cursor("/etc/argon-config-migration"):get("argon", "rpc_stale", "future_option"))
        local used_migration = false
        for _, call in ipairs(c.exports) do
            if call.directory == "/etc/argon-config-migration" and call.savedir == STAGING .. "/uci" then
                used_migration = true
                assert.equal(c.original_raw, call.raw)
            end
        end
        assert.is_true(used_migration)
        assert.is_true(has_command(H.popen_cmds(), "uci -q -c '/etc/argon-config-migration' -C '' -t '" .. STAGING .. "/uci' export argon"))
    end)

    it("refuses conflicting migration/current config before any download or package mutation", function()
        local c = begin()
        local different = sections("light")
        local migration = c.write_config(different, MIGRATION)
        local response = failed(c, "preflight")
        assert.matches("Conflicting Argon migration backup", response.error, 1, true)
        assert.equal(c.original_raw, H.vfs_read(CONFIG))
        assert.equal(migration, H.vfs_read(MIGRATION))
        assert.same({}, c.downloaded)
        assert.same({}, c.installs)
        no_finish()
    end)

    it("handles a genuinely missing original config without manufacturing typography", function()
        local c = begin({ missing_config = true })
        local response = c.theme.update()
        assert.is_true(response.success, response.error or response.details)
        assert.equal("", H.vfs_read(BACKUP))
        local restored = c.snapshot()
        assert.equal(1, #restored)
        assert.equal("normal", restored[1].options.mode)
        assert.equal(".new-argon-package{}\n", H.vfs_read(CSS))
    end)
end)
