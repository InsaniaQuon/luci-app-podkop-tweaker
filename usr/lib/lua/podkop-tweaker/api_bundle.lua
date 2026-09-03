-- Podkop Tweaker | v4.4.0 | 30.08.2026 | non-table items land in skipped
-- Hybrid exception kept as-is: export (transport endpoint)

local H = require("podkop-tweaker.http")
local SRV = require("podkop-tweaker.services")
local S = require("pt-subs-lib")
local BUNDLE = require("podkop-tweaker.bundle")
local AR = require("podkop-tweaker.argon")
local UPD = require("podkop-tweaker.api_update")

local M = {}

local BUNDLE_FORMAT = "podkop-tweaker-bundle"
local BUNDLE_VERSION = 1
local BUNDLE_MAX_SIZE = 4194304

function M.export()
    local http = require("luci.http")
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

    if requested.podkop then
        local c = BUNDLE.read_file("/etc/config/podkop")
        if c then bundle.items.podkop = { content = c } end
    end
    if requested.stubby then
        local c = BUNDLE.read_file("/etc/config/stubby")
        if c then bundle.items.stubby = { content = c } end
    end
    if requested.singbox then
        local c = BUNDLE.read_file(SRV.SINGBOX_CONFIG)
        if c then bundle.items.singbox = { content = c } end
    end
    if requested.fragment then
        local c = BUNDLE.read_file("/etc/config/podkop-fragment")
        if c then bundle.items.fragment = { content = c } end
    end
    if requested.argon and not AR.tab_disabled() then
        bundle.items.argon = { settings = AR.read_settings() }
    end
    if requested.tweaker then
        local c = BUNDLE.read_file("/etc/config/podkop-tweaker")
        if c then bundle.items.tweaker = { content = c } end
    end
    if requested.subs then
        local subs = S.read_subs(SRV.SUBS_FILE)
        bundle.items.subs = { data = subs }
    end

    if not next(bundle.items) then
        http.prepare_content("application/json")
        http.write_json({ error = "No items to export" })
        return
    end

    local str = S.json_stringify(bundle)
    if not str then
        http.prepare_content("application/json")
        http.status(500, "Cannot serialize bundle")
        http.write_json({ error = "Cannot serialize bundle" })
        return
    end

    http.prepare_content("application/octet-stream")
    H.no_cache()
    http.header("Content-Disposition",
        'attachment; filename="' .. os.date("%d.%m.%Y") .. '-podkop-tweaker-bundle-backup.json"')
    http.write(str)
end

function M.import(content, file_raw, sel_param)
    local sys = require("luci.sys")

    if content == "" then
        if type(file_raw) == "table" and file_raw.data then
            content = file_raw.data
        elseif type(file_raw) == "string" then
            content = file_raw
        end
    end
    if content == "" then
        return { error = "Bundle content is empty" }
    end
    if #content > BUNDLE_MAX_SIZE then
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

    local skipped = {}
    for name, _ in pairs(bundle.items) do
        if not BUNDLE.is_known_item(name)
            or type(bundle.items[name]) ~= "table"
            or (selection_used and not selected[name]) then
            table.insert(skipped, name)
        end
    end

    local results = {}
    local env = { subs_file = SRV.SUBS_FILE }

    for _, name in ipairs(BUNDLE.ITEMS) do
        if type(bundle.items[name]) == "table"
            and (not selection_used or selected[name]) then
            local ok, err = BUNDLE.apply_item(name, bundle.items[name], env)
            results[name] = { ok = (ok == true), error = err }
        end
    end

    if env.restart_podkop then sys.exec("/etc/init.d/podkop restart 2>&1") end
    if env.restart_stubby then sys.exec("/etc/init.d/stubby restart 2>&1") end
    if env.restart_singbox then sys.exec("/etc/init.d/sing-box restart 2>&1") end
    local restart_podkop = env.restart_podkop or false

    local any_ok = false
    for _, r in pairs(results) do
        if r.ok then any_ok = true end
    end

    return {
        success = any_ok,
        restarting = restart_podkop,
        results = results,
        skipped = skipped
    }
end

return M
