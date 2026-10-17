-- Argon APK lifecycle: a pinned, resumable package plan and checked UCI/CSS.
local LIB = require("podkop-tweaker.lib")
local ARGON = require("podkop-tweaker.argon")
local S = require("pt-subs-lib")
local SRV = require("podkop-tweaker.services")
local NET = require("podkop-tweaker.net")
local PKG = require("podkop-tweaker.theme_packages")
local CFG = require("podkop-tweaker.theme_config")
local M = {}
local GIT_API_URL = "https://api.github.com/repos/jerrykuku/luci-theme-argon/releases/latest"
local CACHE = "/tmp/pt_argon_theme_check.json"
local STAGING = "/tmp/pt-argon-theme"
local MIGRATION = "/etc/argon-config-migration/argon"
M.STATE = "/etc/podkop-tweaker-argon-update.json"
local STATE_LIMIT = 2 * LIB.UCI_MAX_SIZE + 65536
local TTL = 86400

local function optional_file(path, limit)
    local fd, err, errno = io.open(path, "rb")
    if not fd then return nil, errno ~= 2 and (err or "Cannot open file") or nil end
    local data, read_err = SRV.read_stream(fd, limit)
    local closed = fd:close()
    if not data or not closed then return nil, read_err or "Cannot close file" end
    return data
end

local function checked(command)
    local out = require("luci.sys").exec(SRV.checked_command(command)) or ""
    local details, code = out:match("^(.*)\nPT_EXIT:(%d+)\n$")
    return code == "0", details or out, code
end

local function inventory()
    return PKG.inventory(require("luci.sys").exec("apk list --installed --manifest 2>/dev/null"))
end

function M.installed_version()
    local installed = inventory()
    return installed and installed[PKG.THEME] or nil
end

local function environment(installed)
    if not installed["base-files"] then return false, "Native OpenWrt APK is required" end
    local apk = require("luci.sys").exec("apk --version 2>/dev/null") or ""
    if not apk:match("apk%-tools%s+3%.%d+%.%d+") then return false, "apk-tools 3.x is required" end
    local release = SRV.read_file("/etc/openwrt_release", 8192) or ""
    local version = release:match("DISTRIB_RELEASE=['\"](%d+%.%d+%.%d+)['\"]")
    if not version or LIB.version_lt(version, "25.12.4") then return false, "OpenWrt 25.12.4 or newer is required" end
    local _, base = PKG.version(installed[PKG.THEME])
    if not base or LIB.version_lt(base, "2.4.4") then return false, "Argon 2.4.4 or newer is required" end
    return true
end

local function package_status(name, version)
    local raw = require("luci.sys").exec("apk query --from installed --installed --fields name,version,status --format json --match name " ..
        LIB.shell_escape(name) .. " 2>/dev/null") or ""
    if #raw > 16384 then return false, "APK package status exceeds size limit" end
    local result = S.json_parse(raw)
    if type(result) ~= "table" then return false, "Cannot verify APK package status: " .. name end
    if result.name then result = { result } end
    local found
    for _, item in ipairs(result) do
        if type(item) == "table" and item.name == name then
            if found or item.version ~= version then return false, "Unexpected APK package identity: " .. name end
            found = item
        end
    end
    if not found then return false, "Installed APK package is missing: " .. name end
    local status = found.status
    if status == "installed" then return true end
    if type(status) == "table" and #status == 1 and status[1] == "installed" then return true end
    return false, "APK reports an incomplete installation: " .. name .. ". Repair this package before resuming the update."
end

local function digest(path)
    local out = require("luci.sys").exec("sha256sum " .. LIB.shell_escape(path) .. " 2>/dev/null") or ""
    local hash = out:match("^([a-f0-9]+)%s")
    if hash and #hash == 64 then return hash end
    return nil, "Cannot verify SHA256: " .. path
end

local function store(state)
    local raw = S.json_stringify(state)
    if not raw or #raw > STATE_LIMIT then return false, "Argon recovery state exceeds size limit" end
    return SRV.write_file_atomic(M.STATE, raw, { mode = "600" })
end

local function pending()
    local raw, err = optional_file(M.STATE, STATE_LIMIT)
    if not raw then return nil, err end
    local state = S.json_parse(raw)
    if type(state) ~= "table" or state.schema ~= 1 or not PKG.valid_release(state.release) or
        type(state.steps) ~= "table" or #state.steps > PKG.MAX_PACKAGES or type(state.phase) ~= "string" or
        not CFG.valid_snapshot(state.original) or type(state.original_exists) ~= "boolean" or
        (state.changed ~= nil and type(state.changed) ~= "boolean") or
        type(state.backup_sha256) ~= "string" or #state.backup_sha256 ~= 64 or not state.backup_sha256:match("^[a-f0-9]+$") then
        return nil, "Invalid Argon recovery state; preserve " .. CFG.BACKUP .. " and inspect " .. M.STATE
    end
    local names = {}
    for _, step in ipairs(state.steps) do
        if type(step) ~= "table" or not PKG.own_name(step.name) or names[step.name] or not state.release.packages[step.name] or
            (step.phase ~= "compat" and step.phase ~= "theme" and step.phase ~= "translation") or
            (step.done ~= nil and type(step.done) ~= "boolean") then return nil, "Invalid Argon recovery package plan" end
        names[step.name] = true
    end
    return state
end

local function release_metadata(force)
    if not force then
        local cache = S.json_parse(SRV.read_file(CACHE, 262144))
        if type(cache) == "table" and cache.schema == 2 and type(cache.cached_at) == "number" and
            os.time() >= cache.cached_at and os.time() - cache.cached_at < TTL and PKG.valid_release(cache.release) then return cache.release end
    end
    local raw, err = NET.fetch(GIT_API_URL, 262144, 15, "PodkopTweaker", true)
    if not raw then return nil, err end
    local response = S.json_parse(raw)
    if type(response) == "table" and type(response.message) == "string" and response.message:lower():find("rate limit", 1, true) then
        return nil, "GitHub API rate limit exceeded"
    end
    local release, release_err = PKG.release(response)
    if not release then return nil, release_err end
    local text = S.json_stringify({ schema = 2, release = release, cached_at = os.time() })
    if text then SRV.write_file_atomic(CACHE, text, { mode = "600" }) end
    return release
end

-- Cache release facts only. Installed packages/revisions and resume decisions
-- are always live, including after a manual update or a failed translation.
function M.check(force)
    local installed, err = inventory()
    local current = installed and installed[PKG.THEME]
    if not current then return { current_version = current, update_available = false, error = err or "Argon theme is not installed" } end
    local state, state_err = pending()
    if state_err then return { current_version = current, update_available = false, error = state_err } end
    local release, release_err
    if state then release = state.release else release, release_err = release_metadata(force) end
    if not release then return { current_version = current, update_available = false, error = release_err } end
    local steps, plan_err = PKG.plan(release, installed)
    local supported, support_err = environment(installed)
    local error_text = plan_err or (not supported and support_err or nil)
    return { current_version = current, latest_version = release.version, download_url_apk = release.packages[PKG.THEME].url,
        update_available = error_text == nil and (state ~= nil or #steps > 0), resume_available = state ~= nil,
        phase = state and state.phase or nil, error = error_text }
end

local function download(asset)
    local path = STAGING .. "/" .. asset.name
    local existing = optional_file(path, PKG.MAX_PACKAGE)
    if existing and #existing == asset.size and digest(path) == asset.sha256 then return path end
    local bytes, err = NET.fetch(asset.url, PKG.MAX_PACKAGE, 120, "PodkopTweaker", true)
    if not bytes then return nil, err end
    if #bytes ~= asset.size then return nil, "Downloaded APK size does not match release metadata: " .. asset.name end
    local ok, write_err = SRV.write_file_atomic(path, bytes, { mode = "600" })
    if not ok then return nil, write_err end
    local hash, hash_err = digest(path)
    if hash ~= asset.sha256 then return nil, hash_err or "Downloaded APK checksum mismatch: " .. asset.name end
    return path
end

local function update()
    local state, phase, changed = nil, "preflight", false
    local function fail(message, details)
        if state then
            state.phase = phase
            state.changed = changed
            local saved, err = store(state)
            if not saved then details = (details or "") .. "\nCannot record recovery state: " .. tostring(err) end
        end
        local backup = state and ("\nOriginal Argon configuration: " .. CFG.BACKUP .. "\nResume the update explicitly after resolving this stage.") or ""
        return { success = false, error = message, details = (details or "Stage: " .. phase) .. backup,
            phase = phase, partial = changed, resume_available = state ~= nil }
    end
    local installed, inv_err = inventory()
    if not installed or not installed[PKG.THEME] then return fail(inv_err or "Argon theme is not installed") end
    local supported, support_err = environment(installed)
    if not supported then return fail(support_err) end
    local saved, state_err = pending()
    if state_err then return fail(state_err) end
    local release, steps
    if saved then
        state, release, steps = saved, saved.release, saved.steps
        changed = state.changed == true
        local backup_hash, hash_err = digest(CFG.BACKUP)
        if backup_hash ~= state.backup_sha256 then return fail(hash_err or "Argon recovery backup checksum mismatch") end
        for _, step in ipairs(steps) do if step.done then changed = true end end
    else
        local release_err
        release, release_err = release_metadata(true)
        if not release then return fail(release_err) end
        local plan_err
        steps, plan_err = PKG.plan(release, installed)
        if not steps then return fail(plan_err) end
        if #steps == 0 then return fail("Theme and installed translations are already up to date") end
    end
    local migration, migration_err = optional_file(MIGRATION, LIB.UCI_MAX_SIZE)
    local current, config_err = optional_file(CFG.CONFIG, LIB.UCI_MAX_SIZE)
    if migration_err or config_err then return fail(migration_err or config_err) end
    if migration and current and migration ~= current then
        return fail("Conflicting Argon migration backup", "Review " .. MIGRATION .. " and " .. CFG.CONFIG .. " before resuming; neither file was overwritten.")
    end
    if state and migration and digest(MIGRATION) ~= state.backup_sha256 then return fail("Argon migration backup differs from the saved original") end
    phase = "download"
    local made, mkdir_err = checked("umask 077; mkdir -p " .. STAGING .. "/uci && chmod 700 " .. STAGING .. " " .. STAGING .. "/uci")
    if not made then return fail("Cannot prepare Argon staging", mkdir_err) end
    local paths = {}
    for _, step in ipairs(steps) do
        if not step.done then
            local path, err = download(release.packages[step.name])
            if not path then return fail("Cannot download Argon update", err) end
            paths[step.name] = path
        end
    end
    local function install()
        -- Downloads must not lock the typography form. Re-read under the lock so a
        -- Save completed during a download becomes the actual recovery baseline.
        migration, migration_err = optional_file(MIGRATION, LIB.UCI_MAX_SIZE)
        current, config_err = optional_file(CFG.CONFIG, LIB.UCI_MAX_SIZE)
        if migration_err or config_err then return fail(migration_err or config_err) end
        if migration and current and migration ~= current then return fail("Conflicting Argon migration backup") end
        if state and migration and digest(MIGRATION) ~= state.backup_sha256 then return fail("Argon migration backup differs from the saved original") end
        if not state then
            phase = "backup"
            local original = current or migration or ""
            if original ~= "" then
                local valid, validation_err = LIB.validate_uci_config(original)
                if not valid then return fail("Cannot back up invalid Argon UCI", validation_err) end
            end
            local snapshot, snapshot_err = CFG.snapshot(current == nil and migration ~= nil and "/etc/argon-config-migration" or nil)
            if not CFG.valid_snapshot(snapshot) or original ~= "" and #snapshot == 0 then return fail("Cannot read original Argon UCI", snapshot_err) end
            local written, write_err = SRV.write_file_atomic(CFG.BACKUP, original, { mode = "600" })
            if not written then return fail("Cannot back up Argon configuration", write_err) end
            local hash, hash_err = digest(CFG.BACKUP)
            if not hash then return fail("Cannot verify Argon configuration backup", hash_err) end
            state = { schema = 1, release = release, steps = steps, original = snapshot, original_exists = current ~= nil or migration ~= nil,
                backup_sha256 = hash, phase = phase }
            local recorded, record_err = store(state)
            if not recorded then state = nil; return fail("Cannot create Argon recovery state", record_err) end
        end
        for _, step in ipairs(steps) do
            phase = step.phase
            local desired = release.packages[step.name].version
            local now, now_err = inventory()
            if not now then return fail(now_err) end
            if step.done and now[step.name] ~= desired then return fail("An installed package changed during Argon recovery: " .. step.name) end
            if step.phase == "theme" then
                -- Argon's hook gives the migration copy priority over the live
                -- config. Recheck immediately before invoking it, including Resume.
                local live, live_err = optional_file(CFG.CONFIG, LIB.UCI_MAX_SIZE)
                local handoff, handoff_err = optional_file(MIGRATION, LIB.UCI_MAX_SIZE)
                if live_err or handoff_err then return fail("Cannot verify Argon migration inputs", live_err or handoff_err) end
                if handoff and live and handoff ~= live then return fail("Conflicting Argon migration backup") end
            end
            if now[step.name] == desired then
                local healthy, health_err = package_status(step.name, desired)
                if not healthy then return fail(health_err) end
            else
                local order = PKG.compare(now[step.name], desired)
                if order == 1 then return fail("Refusing to downgrade an installed package: " .. step.name) end
                state.phase = phase
                local recorded, record_err = store(state)
                if not recorded then return fail("Cannot record Argon update stage", record_err) end
                local ok, output = checked("cd / && apk add --allow-untrusted " .. LIB.shell_escape(paths[step.name]))
                local after, after_err = inventory()
                changed = changed or after and after[step.name] ~= now[step.name] or false
                local healthy, health_err = package_status(step.name, desired)
                if not ok then
                    if after and after[step.name] == desired and healthy then
                        output = output .. "\nSelected package is installed at " .. desired .. " with healthy APK status, but APK returned an error. " ..
                            "The operation is paused. Check installed package statuses before explicitly resuming."
                    end
                    return fail("Argon package installation failed: " .. step.name, output)
                end
                if not after or after[step.name] ~= desired then
                    return fail("Installed APK version does not match the update target: " .. step.name, output .. "\n" .. (after_err or "Expected " .. desired))
                end
                if not healthy then return fail(health_err, output) end
            end
            step.done = true
            local recorded, record_err = store(state)
            if not recorded then return fail("Cannot record completed Argon package", record_err) end
            local before_theme = PKG.version(now[PKG.THEME])
            if step.phase == "compat" and state.original_exists and before_theme and before_theme[1] < 3 then
                -- Independently verify the handoff even if a package hook returned
                -- success. A pristine protected file may disappear with its owner.
                local handoff, handoff_err = optional_file(MIGRATION, LIB.UCI_MAX_SIZE)
                local baseline, baseline_err = SRV.read_file(CFG.BACKUP, LIB.UCI_MAX_SIZE)
                if handoff_err or not baseline then return fail("Cannot verify Argon configuration handoff", handoff_err or baseline_err) end
                local live, live_err = optional_file(CFG.CONFIG, LIB.UCI_MAX_SIZE)
                if live_err then return fail("Cannot inspect current Argon configuration", live_err) end
                if live and live ~= baseline then return fail("Argon configuration changed since the saved original; inspect it before resuming") end
                if handoff and handoff ~= baseline then return fail("Argon configuration handoff differs from the original") end
                if not handoff then
                    local prepared, prepare_err = checked("umask 077; mkdir -p /etc/argon-config-migration && chmod 700 /etc/argon-config-migration")
                    if not prepared then return fail("Cannot prepare Argon configuration handoff", prepare_err) end
                    local written, write_err = SRV.write_file_atomic(MIGRATION, baseline, { mode = "600" })
                    if not written then return fail("Cannot preserve Argon configuration handoff", write_err) end
                end
            end
        end
        phase = "verify"
        local final, final_err = inventory()
        if not final or final[PKG.THEME] ~= release.version then return fail("Argon target revision is not installed", final_err) end
        for _, step in ipairs(steps) do
            local desired = release.packages[step.name].version
            if final[step.name] ~= desired then return fail("Argon component revision changed: " .. step.name) end
            local healthy, health_err = package_status(step.name, desired)
            if not healthy then return fail(health_err) end
        end
        phase = "config"
        local original, backup_err = SRV.read_file(CFG.BACKUP, LIB.UCI_MAX_SIZE)
        if not original then return fail("Cannot read saved Argon configuration", backup_err) end
        local integrated = false
        if PKG.version(release.version)[1] >= 3 then
            for _, step in ipairs(steps) do if step.phase == "theme" then integrated = true; break end end
        end
        local restored, restore_err = CFG.restore_missing(original, state.original, integrated)
        if not restored then return fail("Cannot restore missing Argon configuration", restore_err) end
        local preserved, preservation_err = CFG.verify(state.original, integrated)
        if not preserved then return fail("Argon configuration verification failed", preservation_err) end
        phase = "css"
        local final_config, snapshot_err = CFG.snapshot()
        if not final_config then return fail("Cannot read Argon typography", snapshot_err) end
        for _, section in ipairs(final_config) do
            if section.name == "typography" and section.kind == "typography" then
                local applied, css_err = ARGON.apply(section.options)
                if not applied then return fail("Cannot restore Argon typography CSS", css_err) end
                local stale, stale_err = ARGON.check_stale()
                if stale ~= false then return fail("Cannot verify Argon typography CSS", stale_err or "Typography CSS is missing") end
                break
            end
        end
        phase = "rpcd"
        local reloaded, reload_err = checked("/etc/init.d/rpcd reload")
        if not reloaded then return fail("Argon installed, but RPC reload failed", reload_err) end
        phase = "cache"
        local cleared, clear_err = checked("rm -rf /tmp/luci-*")
        if not cleared then return fail("Argon installed, but LuCI cache cleanup failed", clear_err) end
        local cached, cache_err = optional_file(CACHE, 262144)
        if cache_err or cached and not os.remove(CACHE) then return fail("Cannot remove Argon release cache", cache_err) end
        phase = "cleanup"
        local cleaned, clean_err = checked("rm -rf " .. STAGING)
        if not cleaned then return fail("Cannot clean Argon package staging", clean_err) end
        if not os.remove(M.STATE) then return fail("Cannot finish Argon recovery state") end
        return { success = true, new_version = release.version }
    end
    -- Package hooks also mutate Argon's UCI/CSS. Keep those stages in the same
    -- resource as manual typography and bundle operations, after network IO.
    local outcome
    local result, lock_err, uncertain = ARGON.with_lock(function()
        outcome = install()
        return outcome
    end)
    if result then return result end
    local response = fail("Cannot coordinate Argon configuration update", lock_err)
    if outcome and outcome.error then
        response.details = outcome.error .. (outcome.details and ("\n" .. outcome.details) or "") .. "\n" .. response.details
    end
    response.lock_error, response.unknown = lock_err, uncertain or nil
    return response
end

function M.update(restart_id)
    return require("podkop-tweaker.web_restart").run(restart_id, "theme", update)
end

return M
