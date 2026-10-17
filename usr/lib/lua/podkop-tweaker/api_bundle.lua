-- Podkop Tweaker | checked bundle export and per-item import finishing
-- Hybrid exception: export owns the download transport.

local H = require("podkop-tweaker.http")
local SRV = require("podkop-tweaker.services")
local S = require("pt-subs-lib")
local BUNDLE = require("podkop-tweaker.bundle")
local AR = require("podkop-tweaker.argon")
local UPD = require("podkop-tweaker.api_update")

local M = {}

local BUNDLE_FORMAT = "podkop-tweaker-bundle"
local BUNDLE_VERSION = 1
M.MAX_SIZE = 4194304

local function copy_result(info)
    local result = {}
    for key, value in pairs(type(info) == "table" and info or {}) do result[key] = value end
    return result
end

-- A later lock/exception must not hide the original error or any native output.
local function finishing_failure(outcome, message, details, lock_error, unknown)
    local result = copy_result(outcome)
    if result.error then
        result.primary_error = result.primary_error or result.error
        result.primary_details = result.primary_details or result.details
        result.details = tostring(result.error) .. (result.details and ("\n" .. result.details) or "")
    end
    if details then result.details = (result.details and (result.details .. "\n") or "") .. tostring(details) end
    result.success, result.error = false, message
    if lock_error then result.lock_error = lock_error end
    result.unknown = unknown == true or result.unknown or nil
    return result
end

function M.export()
    local http = require("luci.http")
    H.no_cache()
    local requested = {}
    local items_param = http.formvalue("items") or ""
    for it in items_param:gmatch("[%w%-]+") do
        if BUNDLE.is_known_item(it) then requested[it] = true end
    end

    local bundle = {
        format = BUNDLE_FORMAT,
        version = BUNDLE_VERSION,
        created = os.date("%Y-%m-%d %H:%M"),
        tweaker_version = UPD.get_version(),
        items = {}
    }

    local errors, omitted, details = {}, {}, {}
    local status, unknown = 404, false
    for _, name in ipairs(BUNDLE.ITEMS) do
        if requested[name] then
            local called, item, err, info = pcall(BUNDLE.export_item, name)
            if not called then
                item, err, info = nil, "Cannot read selected component", { status = 500, details = "Internal read error" }
            end
            if item then
                bundle.items[name] = item
            elseif err then
                info = info or {}
                errors[name] = { error = err, details = info.details, path = info.path, status = info.status or 500, unknown = info.unknown }
                if info.unknown == true then unknown = true end
                if (info.status or 500) ~= 404 then status = 500 end
                details[#details + 1] = name .. (info.path and " (" .. info.path .. ")" or "") .. ": " .. err
                    .. (info.details and ": " .. tostring(info.details) or "")
            elseif info then
                omitted[name] = info
            end
        end
    end
    if next(errors) then
        http.status(status, "Cannot export selected bundle components")
        http.prepare_content("application/json")
        http.write_json({ success = false, error = "Cannot export selected bundle components",
            details = table.concat(details, "\n") .. "\nRestore the affected component or deselect it before exporting.",
            errors = errors, omitted = next(omitted) and omitted or nil, unknown = unknown or nil })
        return
    end

    if not next(bundle.items) then
        http.status(next(omitted) and 404 or 400, "No items to export")
        http.prepare_content("application/json")
        http.write_json({ error = "No items to export", omitted = next(omitted) and omitted or nil })
        return
    end
    -- Additive v1 metadata: older importers ignore it; absent optional components
    -- are explicit instead of indistinguishable from unreadable selected files.
    if next(omitted) then bundle.omitted = omitted end

    local str = S.json_stringify(bundle)
    if type(str) ~= "string" or #str > M.MAX_SIZE then
        http.prepare_content("application/json")
        http.status(500, "Cannot serialize bundle")
        http.write_json({ error = "Cannot serialize bundle", details = type(str) == "string" and "Bundle exceeds the 4MB import limit" or nil })
        return
    end

    http.prepare_content("application/octet-stream")
    http.header("Content-Disposition",
        'attachment; filename="' .. os.date("%d.%m.%Y") .. '-podkop-tweaker-bundle-backup.json"')
    http.write(str)
end

function M.import(content, file_raw, sel_param)
    if content == nil then content = "" end
    if content == "" then
        if type(file_raw) == "table" and file_raw.data then
            content = file_raw.data
        elseif type(file_raw) == "string" then
            content = file_raw
        end
    end
    if type(content) ~= "string" then return { error = "Bundle content must be text" } end
    if content == "" then
        return { error = "Bundle content is empty" }
    end
    if #content > M.MAX_SIZE then
        return { error = "Bundle too large (max 4MB)" }
    end
    if content:find("\0", 1, true) then
        return { error = "Invalid content: contains null bytes" }
    end

    local bundle = S.json_parse(content)
    if type(bundle) ~= "table" or bundle.format ~= BUNDLE_FORMAT then
        return { error = "Not a valid Podkop Tweaker bundle" }
    end
    local bundle_ver = tonumber(bundle.version) or 0
    if bundle_ver < 1 or bundle_ver > BUNDLE_VERSION then
        return { error = "Unsupported bundle version: " .. tostring(bundle.version) }
    end
    if type(bundle.items) ~= "table" or not next(bundle.items) then
        return { error = "Bundle has no items" }
    end

    local selection_used = false
    local selected = {}
    if sel_param and sel_param ~= "" then
        selection_used = true
        for it in sel_param:gmatch("[%w%-]+") do selected[it] = true end
    end

    -- argon settings are invisible when the tab is hidden: ignore the item
    -- entirely (both directions) instead of surfacing a per-item error
    local argon_ignored = AR.tab_disabled()

    local skipped = {}
    for name, _ in pairs(bundle.items) do
        if not BUNDLE.is_known_item(name)
            or type(bundle.items[name]) ~= "table"
            or (name == "argon" and argon_ignored)
            or (selection_used and not selected[name]) then
            table.insert(skipped, name)
        end
    end

    local results = {}
    local env = { subs_file = SRV.SUBS_FILE, item_states = {} }

    for _, name in ipairs(BUNDLE.ITEMS) do
        if type(bundle.items[name]) == "table"
            and not (name == "argon" and argon_ignored)
            and (not selection_used or selected[name]) then
            local called, ok, err, info = pcall(BUNDLE.apply_item, name, bundle.items[name], env)
            if not called then
                info = finishing_failure(env.item_states[name], "Cannot apply item: internal error", ok, nil, true)
                ok, err = false, info.error
            end
            local result = copy_result(info)
            result.success = nil
            result.unknown = result.unknown == true or (type(result.restart) == "table" and result.restart.unknown == true) or nil
            result.ok = ok == true and not result.unknown
            result.error = err or result.error or (result.unknown and "Item outcome is unknown" or nil)
            results[name] = result
        end
    end

    local restarts = {}
    for _, name in ipairs({ "podkop", "stubby", "singbox" }) do
        if env["restart_" .. name] and results[name].unknown ~= true then
            local observed
            local called, restart, lock_err, uncertain = pcall(SRV.with_lock, name, function()
                observed = SRV.restart_service(name)
                return observed
            end)
            if not called then
                restart = finishing_failure(observed, "Cannot request service restart: internal error", restart, nil, true)
            elseif restart == nil then
                local message = lock_err or "Cannot acquire or release service restart lock"
                restart = finishing_failure(observed, message, message, message, uncertain == true or type(observed) == "table")
            elseif type(restart) ~= "table" then
                restart = finishing_failure(observed, "Invalid service restart response", nil, nil, true)
            elseif restart.unknown == true then
                restart = copy_result(restart)
                restart.success = false
                restart.error = restart.error or "Service restart outcome is unknown"
            end
            restarts[name] = restart
            local result = results[name]
            result.restart = restart
            result.restarting = restart.restarting == true
            result.verification_required = restart.verification_required
            if result.verification_required == nil then result.verification_required = true end
            for _, key in ipairs({ "previous_running", "previous_instance", "previous_identity_known" }) do result[key] = restart[key] end
            result.unknown = restart.unknown == true or result.unknown or nil
            for _, key in ipairs({ "lock_error", "primary_error", "primary_details" }) do
                if restart[key] ~= nil then result[key] = restart[key] end
            end
            if restart.success ~= true then
                result.ok = false
                result.restart_required = restart.restarting ~= true or nil
                result.error = "Configuration saved, but " .. tostring(restart.error or "service restart failed")
                if restart.details then
                    result.details = (result.details and (result.details .. "\n") or "") .. restart.details
                end
            end
        end
    end

    local any_ok, any_applied, any_error, any_unknown = false, false, false, false
    for _, r in pairs(results) do
        if r.ok then any_ok = true end
        if r.applied == true then any_applied = true end
        if r.unknown == true or (type(r.restart) == "table" and r.restart.unknown == true) then any_unknown = true end
        if not r.ok then
            any_error = true
            if r.applied then r.partial = true end
        end
    end

    local response = {
        success = any_ok,
        applied = any_applied,
        unknown = any_unknown or nil,
        partial = any_error and (any_ok or any_applied),
        complete = any_ok and not any_error and not any_unknown,
        restarting = results.podkop and results.podkop.restarting == true or false,
        restarts = restarts,
        results = results,
        skipped = skipped
    }
    -- Legacy restarting means Podkop only; expose its checked generation facts
    -- at the same level for existing watcher call sites. Other services are scoped.
    if restarts.podkop then
        for _, key in ipairs({ "verification_required", "previous_running", "previous_instance", "previous_identity_known" }) do
            response[key] = results.podkop[key]
        end
    end
    return response
end

return M
