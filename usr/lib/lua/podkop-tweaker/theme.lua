-- Podkop Tweaker | v4.5.0 | 03.09.2026 | Argon theme: version detect, 24h GitHub check, one-shot update flow
-- Author: InsaniaQuon

local LIB = require("podkop-tweaker.lib")
local ARGON = require("podkop-tweaker.argon")
local S = require("pt-subs-lib")

local M = {}

local GIT_API_URL = "https://api.github.com/repos/jerrykuku/luci-theme-argon/releases/latest"
local CHECK_CACHE_FILE = "/tmp/pt_argon_theme_check.json"
local CHECK_CACHE_TTL = 86400
local PKG_MAX_SIZE = 2097152

-- Detect installed theme version via package manager (apk first, then opkg).
-- Returns version, manager ("apk"|"opkg") or nil, nil when the theme is absent.
local function detect()
    local sys = require("luci.sys")
    local out = sys.exec("apk list --installed 2>/dev/null | grep '^luci-theme-argon'")
    if out and out ~= "" then
        return out:match("(%d+%.%d+%.%d+)"), "apk"
    end
    out = sys.exec("opkg list-installed 2>/dev/null | grep '^luci-theme-argon'")
    if out and out ~= "" then
        return out:match("(%d+%.%d+%.%d+)"), "opkg"
    end
    return nil, nil
end

function M.installed_version()
    return detect()
end

local function read_cache()
    local fd = io.open(CHECK_CACHE_FILE, "r")
    if not fd then return nil end
    local raw = fd:read("*a")
    fd:close()
    return S.json_parse(raw)
end

local function write_cache(entry)
    local str = S.json_stringify(entry)
    if not str then return end
    local fd = io.open(CHECK_CACHE_FILE, "w")
    if fd then
        fd:write(str)
        fd:close()
    end
end

-- Check GitHub for the latest release. Auto mode (force=false) serves the
-- cached entry while it is younger than CHECK_CACHE_TTL; force bypasses TTL.
-- Returns a table with current/latest/update_available + asset URLs.
function M.check(force)
    local sys = require("luci.sys")
    if not force then
        local cache = read_cache()
        if cache and cache.cached_at
            and (os.time() - cache.cached_at) < CHECK_CACHE_TTL then
            return cache
        end
    end

    local raw = sys.exec("curl -sL -m 10 -A 'PodkopTweaker' '" .. GIT_API_URL .. "' 2>/dev/null")
    if not raw or raw == "" then
        return { error = "Failed to connect to GitHub" }
    end
    local release = S.json_parse(raw)
    if not release then
        return { error = "Failed to parse GitHub response" }
    end
    if release.message and (release.message:match("rate limit") or release.message:match("API rate")) then
        return { error = "GitHub API rate limit exceeded" }
    end

    local latest = (release.tag_name or ""):gsub("^v", "")
    local url_apk, url_ipk = "", ""
    if release.assets and type(release.assets) == "table" then
        for _, asset in ipairs(release.assets) do
            if asset.browser_download_url then
                if asset.name:match("^luci%-theme%-argon%-[%d%.]+%-r%d+%.apk$") then
                    url_apk = asset.browser_download_url
                elseif asset.name:match("^luci%-theme%-argon_[%d%.]+_all%.ipk$") then
                    url_ipk = asset.browser_download_url
                end
            end
        end
    end

    local ver = M.installed_version()
    local entry = {
        current_version = ver,
        latest_version = latest,
        update_available = (ver ~= nil) and LIB.version_lt(ver, latest) or false,
        download_url_apk = url_apk,
        download_url_ipk = url_ipk,
        cached_at = os.time()
    }
    write_cache(entry)
    return entry
end

-- One-shot update flow: download matching asset -> snapshot typography ->
-- install (apk/opkg, exit-code checked) -> restore typography + reinject CSS ->
-- clear LuCI caches -> restart uhttpd.
function M.update()
    local sys = require("luci.sys")
    local ver, manager = detect()
    if not ver then
        return { error = "Argon theme is not installed" }
    end

    local info = M.check(true)
    if info.error then
        return { error = info.error }
    end
    if not info.update_available then
        return { error = "Theme is already up to date" }
    end

    local url = (manager == "apk") and info.download_url_apk or info.download_url_ipk
    if not url or url == "" then
        return { error = "No matching package asset for " .. manager }
    end
    if not url:match("^https://github%.com/jerrykuku/luci%-theme%-argon/releases/") then
        return { error = "Invalid download URL" }
    end

    local tmp_dir = "/tmp/pt-argon-theme"
    sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
    sys.exec("mkdir -p " .. tmp_dir .. " 2>/dev/null")
    local pkg_path = tmp_dir .. "/theme." .. manager
    sys.exec("curl -sL -m 120 -o " .. pkg_path .. " " .. S.shell_escape(url) .. " 2>/dev/null")

    local st = io.open(pkg_path, "r")
    if not st then
        sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
        return { error = "Failed to download theme package" }
    end
    local size = st:seek("end")
    st:close()
    if size > PKG_MAX_SIZE then
        sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
        return { error = "Theme package too large" }
    end

    -- typography snapshot: survives the cascade.css replacement
    local snapshot = ARGON.read_settings()

    -- `cd /` first: package hooks (post-upgrade) resolve paths against the
    -- current directory; CGI processes may run from an odd/deleted cwd and
    -- apk then dies with "fchdir: Not a directory".
    local install_cmd
    if manager == "apk" then
        install_cmd = "cd / && apk add --allow-untrusted " .. pkg_path .. " 2>&1; echo EXIT:$?"
    else
        install_cmd = "cd / && opkg install " .. pkg_path .. " 2>&1; echo EXIT:$?"
    end
    local out = sys.exec(install_cmd)
    sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
    local exit_code = out:match("EXIT:(%d+)") or "1"

    -- Oracle by installed version: package hooks may fail noisily (e.g. apk
    -- post-upgrade "fchdir" in non-interactive environments) AFTER the files
    -- are already unpacked. If the version matches the target, treat the
    -- install as successful and continue the restore flow.
    local now_ver = M.installed_version()
    if exit_code ~= "0" then
        if not (now_ver and info.latest_version and now_ver == info.latest_version) then
            local msg = out:gsub("EXIT:%d+%s*$", ""):match("^%s*(.-)%s*$") or "install failed"
            if #msg > 200 then msg = msg:sub(1, 200) .. "..." end
            return { success = false, error = msg }
        end
        -- hook noise; proceed with the restore
    end

    ARGON.save_uci_fields(snapshot)
    ARGON.apply()

    os.execute("rm -rf /tmp/luci-* 2>/dev/null")
    os.execute("nohup /etc/init.d/uhttpd restart >/dev/null 2>&1 &")

    return { success = true, new_version = now_ver or info.latest_version }
end

return M
