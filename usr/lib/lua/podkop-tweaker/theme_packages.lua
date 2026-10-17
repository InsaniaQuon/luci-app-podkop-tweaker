-- Stable Argon APK metadata. Release URLs, versions and digests are canonical.
local LIB = require("podkop-tweaker.lib")
local M = {}
M.THEME = "luci-theme-argon"
M.COMPAT = "luci-app-argon-config"
M.MAX_PACKAGE = 2097152
M.MAX_PACKAGES = 32

function M.version(value)
    if type(value) ~= "string" or #value > 64 then return nil end
    local a, b, c, revision = value:match("^(%d+)%.(%d+)%.(%d+)%-r(%d+)$")
    if not a then return nil end
    local parts = { tonumber(a), tonumber(b), tonumber(c), tonumber(revision) }
    for _, n in ipairs(parts) do if n > 999999 then return nil end end
    local base = a .. "." .. b .. "." .. c
    if base ~= string.format("%d.%d.%d", parts[1], parts[2], parts[3]) or tostring(parts[4]) ~= revision then return nil end
    return parts, base
end

function M.compare(a, b)
    local va, vb = M.version(a), M.version(b)
    if not va or not vb then return nil end
    for i = 1, 4 do
        if va[i] < vb[i] then return -1 end
        if va[i] > vb[i] then return 1 end
    end
    return 0
end

function M.own_name(name)
    return name == M.THEME or name == M.COMPAT or type(name) == "string" and
        #name <= 80 and name:match("^luci%-i18n%-argon%-config%-[a-z][a-z0-9%-]*$") ~= nil
end

function M.inventory(raw)
    if type(raw) ~= "string" or raw == "" or #raw > 262144 then return nil, "Cannot read installed APK packages" end
    local packages = {}
    for line in raw:gmatch("[^\r\n]+") do
        local name, version = line:match("^([a-z0-9][a-z0-9%+_.%-]*)%s+([%w%+_.:~%-]+)%s*$")
        -- Older callers used APK's human-readable list; retain read compatibility.
        if not name then
            name, version = line:match("^(luci%-theme%-argon)%-(%d+%.%d+%.%d+%-r%d+)%s")
        end
        if name and (M.own_name(name) or name == "base-files") then
            if packages[name] or #version > 96 then return nil, "Ambiguous installed APK metadata" end
            packages[name] = version
        end
    end
    return packages
end

function M.valid_asset(asset, tag, name, version)
    return type(asset) == "table" and M.own_name(name) and M.version(version) ~= nil and
        asset.name == name .. "-" .. version .. ".apk" and asset.version == version and
        asset.url == "https://github.com/jerrykuku/luci-theme-argon/releases/download/" .. tag .. "/" .. asset.name and
        type(asset.size) == "number" and asset.size == math.floor(asset.size) and asset.size > 0 and asset.size <= M.MAX_PACKAGE and
        type(asset.sha256) == "string" and #asset.sha256 == 64 and asset.sha256:match("^[a-f0-9]+$") ~= nil
end

function M.release(release)
    if type(release) ~= "table" or release.prerelease == true or release.draft == true then return nil, "Invalid stable Argon release" end
    local tag = release.tag_name
    local base = type(tag) == "string" and tag:match("^v(%d+%.%d+%.%d+)$")
    if not base or not M.version(base .. "-r0") or type(release.assets) ~= "table" or #release.assets > 128 then
        return nil, "Invalid Argon release metadata"
    end
    local candidates, version = {}, nil
    for _, item in ipairs(release.assets) do
        if type(item) == "table" and type(item.name) == "string" then
            local name, ver = item.name:match("^(luci[%w%-]+)%-(%d+%.%d+%.%d+%-r%d+)%.apk$")
            local _, asset_base = M.version(ver)
            if name and M.own_name(name) and asset_base == base then
                local asset = { name = item.name, version = ver, url = item.browser_download_url,
                    size = item.size, sha256 = type(item.digest) == "string" and item.digest:match("^sha256:([a-f0-9]+)$") }
                if not M.valid_asset(asset, tag, name, ver) then return nil, "Invalid Argon APK asset: " .. name end
                local key = name .. ":" .. ver
                if candidates[key] then return nil, "Duplicate Argon APK asset" end
                candidates[key] = asset
                if name == M.THEME and (not version or M.compare(version, ver) == -1) then version = ver end
            end
        end
    end
    if not version then return nil, "No matching APK asset for Argon" end
    local packages = {}
    for key, asset in pairs(candidates) do
        if asset.version == version then packages[key:sub(1, #key - #version - 1)] = asset end
    end
    return { tag = tag, version = version, packages = packages }
end

function M.valid_release(release)
    if type(release) ~= "table" or type(release.tag) ~= "string" or
        not release.tag:match("^v%d+%.%d+%.%d+$") or not M.version(release.version) or type(release.packages) ~= "table" then return false end
    local _, base = M.version(release.version)
    if release.tag ~= "v" .. base then return false end
    local count = 0
    for name, asset in pairs(release.packages) do
        count = count + 1
        if count > M.MAX_PACKAGES or not M.valid_asset(asset, release.tag, name, release.version) then return false end
    end
    return release.packages[M.THEME] ~= nil
end

function M.plan(release, installed)
    if not M.valid_release(release) then return nil, "Invalid Argon update target" end
    local current = installed[M.THEME]
    local parts, base = M.version(current)
    if not parts or LIB.version_lt(base, "2.4.4") then return nil, "Argon 2.4.4 or newer is required" end
    if M.compare(current, release.version) == 1 then return nil, "Argon package downgrade is not supported" end
    local steps = {}
    local function add(name, phase)
        local asset = release.packages[name]
        if not asset then return false, "Missing release APK for installed package: " .. name end
        steps[#steps + 1] = { name = name, phase = phase }
        return true
    end
    local target = M.version(release.version)
    local compat = installed[M.COMPAT] and M.version(installed[M.COMPAT])
    if installed[M.COMPAT] and not compat then return nil, "Unsupported installed Argon Config version" end
    if target[1] >= 3 and compat and compat[1] < 3 then
        local ok, err = add(M.COMPAT, "compat")
        if not ok then return nil, err end
    end
    if M.compare(current, release.version) == -1 then add(M.THEME, "theme") end
    local translations = {}
    for name, ver in pairs(installed) do
        if M.own_name(name) and name ~= M.THEME and name ~= M.COMPAT then
            local order = M.compare(ver, release.version)
            if ver == "0" or ver == "unknown" then order = -1 end
            if order == nil then return nil, "Unsupported installed translation version: " .. name end
            if order == -1 then translations[#translations + 1] = name end
        end
    end
    table.sort(translations)
    for _, name in ipairs(translations) do
        local ok, err = add(name, "translation")
        if not ok then return nil, err end
    end
    return steps
end

return M
