-- Podkop Tweaker | v4.7.1 | 09.10.2026 | explicit same-version local reinstall

local SRV = require("podkop-tweaker.services")
local LIB = require("podkop-tweaker.lib")
local S = require("pt-subs-lib")
local ARCHIVE = require("podkop-tweaker.archive")
local NET = require("podkop-tweaker.net")

local M = {}

local GIT_REPO = "InsaniaQuon/luci-app-podkop-tweaker"
local GIT_API_URL = "https://api.github.com/repos/" .. GIT_REPO .. "/releases/latest"
local CHECK_CACHE_FILE = "/tmp/tweaker_check_cache.json"
local CHECK_CACHE_TTL = 86400

M.UPLOAD_MAX_SIZE = 128000

-- Files removed in newer versions; cleaned up after every successful self-update
local DEPRECATED_PATHS = {
    "/usr/lib/lua/luci/view/podkop-tweaker/podkop-tweaker-css.htm"
}

local function cleanup_deprecated()
    for _, p in ipairs(DEPRECATED_PATHS) do
        os.remove(p)
    end
end

local function cleanup_tmp(tmp_dir)
    local sys = require("luci.sys")
    sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
end

local function read_cache()
    local fd = io.open(CHECK_CACHE_FILE, "r")
    if not fd then return nil end
    local raw = fd:read("*a")
    fd:close()
    return S.json_parse(raw)
end

local VERSION = ""

function M.init(version)
    VERSION = version or ""
end

function M.get_version()
    return VERSION
end

function M.cached_latest()
    local latest = nil
    local tweaker_cache = read_cache()
    if tweaker_cache and tweaker_cache.latest_version and tweaker_cache.cached_at then
        local elapsed = os.time() - tweaker_cache.cached_at
        if elapsed < CHECK_CACHE_TTL then
            latest = tweaker_cache.latest_version
        end
    end
    return latest
end

local function extract_version_from_file(dir_prefix)
    local ctrl_path = dir_prefix .. "/usr/lib/lua/luci/controller/podkop-tweaker.lua"
    local fs = require("nixio").fs
    if not fs.lstat or not fs.lstat(ctrl_path) or fs.lstat(ctrl_path).type ~= "reg" then return nil end
    local content = SRV.read_file(ctrl_path, ARCHIVE.MAX_FILE_SIZE)
    if not content then return nil end
    return content:match('local%s+APP_VERSION%s*=%s*"(%d+%.%d+%.%d+[a-zA-Z0-9_.%-]*)"')
end

local function run_checked(command)
    local sys = require("luci.sys")
    local raw = sys.exec("(" .. command .. ") 2>&1; printf '\\nPT_EXIT:%s\\n' \"$?\"") or ""
    local details, status = raw:match("^(.*)\nPT_EXIT:(%d+)\n$")
    return status == "0", details or raw
end

local function validate_stage(dir, manifest, relaxed)
    if type(manifest) ~= "table" or type(manifest.entries) ~= "table" or #manifest.entries > ARCHIVE.MAX_MEMBERS then
        return nil, "Invalid update manifest"
    end
    local fs = require("nixio").fs
    if not fs.lstat then return nil, "Archive file-type checks are unavailable" end
    local files, seen, size, controller = {}, {}, 0, false
    for _, entry in ipairs(manifest.entries) do
        if type(entry) ~= "table" or type(entry.path) ~= "string" or seen[entry.path] or
            type(entry.size) ~= "number" or entry.size < 0 or entry.size ~= math.floor(entry.size) or entry.size > ARCHIVE.MAX_FILE_SIZE then
            return nil, "Invalid archive metadata"
        end
        seen[entry.path] = true
        local directory = entry.kind == "dir"
        if entry.kind ~= "reg" and not directory then return nil, "Unsupported extracted file type" end
        local canonical = ARCHIVE.canonical_path(entry.path, directory)
        if canonical ~= entry.path or (not directory and not ARCHIVE.is_valid_path(entry.path, relaxed)) then return nil, "Archive path is not allowed" end
        local st = fs.lstat(dir .. "/" .. entry.path)
        if not st or st.type ~= entry.kind or (not directory and st.size ~= entry.size) then
            return nil, "Extracted member does not match manifest: " .. entry.path
        end
        size = size + entry.size
        if size > ARCHIVE.MAX_EXPANDED_SIZE then return nil, "Archive expanded size is too large" end
        if not directory then
            files[#files + 1] = entry.path
            if entry.path == ARCHIVE.CONTROLLER then controller = true end
        end
    end
    if not controller then return nil, "Controller file not found in archive" end
    return files
end

local function prepare_archive(bytes, dir, relaxed)
    cleanup_tmp(dir)
    local made, make_err = run_checked("mkdir -p " .. LIB.shell_escape(dir))
    if not made then return nil, "Cannot create staging directory: " .. make_err end
    local archive_path = dir .. (relaxed and "/download.tar.gz" or "/upload.tar.gz")
    local written, write_err = SRV.write_file_atomic(archive_path, bytes)
    if not written then return nil, write_err end
    local manifest, inspect_err = ARCHIVE.inspect(archive_path, relaxed)
    if not manifest then cleanup_tmp(dir); return nil, inspect_err end
    local extracted, extract_err = run_checked("tar -xzf " .. LIB.shell_escape(archive_path) .. " -C " .. LIB.shell_escape(dir))
    if not extracted then cleanup_tmp(dir); return nil, "Cannot extract archive: " .. extract_err end
    local files, validate_err = validate_stage(dir, manifest, relaxed)
    if not files then cleanup_tmp(dir); return nil, validate_err end
    local version = extract_version_from_file(dir)
    if not version then cleanup_tmp(dir); return nil, "Controller version is missing" end
    manifest.format, manifest.archive_version = "pt-update-manifest", version
    local encoded = S.json_stringify(manifest)
    if not encoded or not SRV.write_file_atomic(dir .. "/.pt-manifest.json", encoded) then
        return nil, "Cannot save update manifest"
    end
    return version, nil, files
end

function M.upload(file_data_b64, file_name)
    if file_data_b64 == "" then
        return { error = "No file uploaded" }
    end

    local file_data = S.b64decode(file_data_b64, M.UPLOAD_MAX_SIZE + 1)
    return M.upload_binary(file_data, file_name)
end

-- Multipart uploads carry the original bytes, avoiding LuCI's 100 KiB
-- limit on buffered text fields. Both transports share archive validation.
function M.upload_binary(file_data, file_name)
    if type(file_data) ~= "string" or file_data == "" then
        return { error = "Invalid archive" }
    end

    if #file_data > M.UPLOAD_MAX_SIZE then
        return { error = "Invalid archive" }
    end

    if type(file_name) ~= "string"
        or not file_name:match("luci%-app%-podkop%-tweaker%-v.+%.tar%.gz$") then
        return { error = "Invalid archive" }
    end

    local archive_ver, prepare_err = prepare_archive(file_data, "/tmp/pt-update", false)
    if not archive_ver then return { error = "Invalid archive", details = prepare_err } end

    local can_update = LIB.version_lt(VERSION, archive_ver)
    local same_version = archive_ver == VERSION

    return {
        success = true,
        current_version = VERSION,
        archive_version = archive_ver,
        can_update = can_update,
        same_version = same_version
    }
end

-- Shared apply pipeline: copy files, drop deprecated orphans, clean tmp + caches, restart uhttpd
local function apply_extracted(extract_dir, tmp_dir, relaxed, files)
    local sys = require("luci.sys")
    local copied, err = S.apply_files_from_dir(extract_dir, relaxed, files)
    if err then return copied, err end
    cleanup_deprecated()
    cleanup_tmp(tmp_dir)
    sys.exec("rm -rf /tmp/luci-modulecache 2>/dev/null")
    sys.exec("nohup /etc/init.d/uhttpd restart >/dev/null 2>&1 &")
    return copied
end

function M.apply(reinstall_raw)
    local nixio = require("nixio")

    local tmp_dir = "/tmp/pt-update"
    local extract_dir = tmp_dir

    if not nixio.fs.stat(extract_dir) then
        return { error = "No archive uploaded" }
    end

    local manifest = S.json_parse(SRV.read_file(tmp_dir .. "/.pt-manifest.json", 131072))
    if type(manifest) ~= "table" or manifest.format ~= "pt-update-manifest" then return { error = "No validated archive uploaded" } end
    local files, stage_err = validate_stage(tmp_dir, manifest, false)
    local archive_ver = files and extract_version_from_file(extract_dir)
    if not archive_ver or archive_ver ~= manifest.archive_version then return { error = "Invalid archive", details = stage_err or "Controller version changed" } end

    local reinstall = reinstall_raw == "1"
    if reinstall and archive_ver ~= VERSION then
        return { error = "Reinstall is only allowed for the exact installed version" }
    end
    if not reinstall and not LIB.version_lt(VERSION, archive_ver) then
        return { error = "Archive version is not newer than installed" }
    end

    local copied, apply_err = apply_extracted(extract_dir, tmp_dir, false, files)
    if apply_err then return { success = false, error = "Update application failed", details = apply_err, files_copied = copied, staging_retained = true } end

    local response = {
        success = true,
        new_version = archive_ver,
        files_copied = copied
    }
    if reinstall then response.reinstalled = true end
    return response
end

function M.clear_cache()
    local sys = require("luci.sys")

    os.execute("rm -rf /tmp/luci-* 2>/dev/null")
    os.remove(CHECK_CACHE_FILE)

    sys.exec("nohup /etc/init.d/uhttpd restart >/dev/null 2>&1 &")

    return { success = true }
end

function M.read_log()
    local lines = {}
    local n = 0
    local fd = io.open(SRV.UPDATE_LOG_FILE, "r")
    if fd then
        for line in fd:lines() do
            n = n + 1
            lines[n] = line
        end
        fd:close()
    end
    return { lines = lines }
end

function M.check_update_force()
    os.remove(CHECK_CACHE_FILE)
    return M.check_update()
end

function M.check_update()
    local sys = require("luci.sys")

    local cache = read_cache()
    if cache and cache.cached_at then
        local elapsed = os.time() - cache.cached_at
        if elapsed < CHECK_CACHE_TTL then
            return {
                error = "rate_limited",
                retry_after = CHECK_CACHE_TTL - elapsed
            }
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

    local tag_name = release.tag_name or ""
    local latest_ver = tag_name:gsub("^v", "")
    local download_url = ""

    if release.assets and type(release.assets) == "table" then
        for _, asset in ipairs(release.assets) do
            if type(asset) == "table" and M.valid_git_url(asset.browser_download_url) then
                download_url = asset.browser_download_url
                break
            end
        end
    end

    local update_available = LIB.version_lt(VERSION, latest_ver)

    local cache_entry = {
        current_version = VERSION,
        latest_version = latest_ver,
        update_available = update_available,
        download_url = download_url,
        cached_at = os.time()
    }
    local cache_str = S.json_stringify(cache_entry)
    if cache_str then
        SRV.write_file_atomic(CHECK_CACHE_FILE, cache_str)
    end

    return {
        current_version = VERSION,
        latest_version = latest_ver,
        update_available = update_available,
        download_url = download_url
    }
end

function M.git_update(download_url, force_raw)

    local force = force_raw == "1"

    if download_url == "" then
        return { error = "Download URL is required" }
    end
    if not M.valid_git_url(download_url) then
        return { error = "Invalid download URL" }
    end

    local tmp_dir = "/tmp/pt-git-update"
    local bytes, download_err = NET.fetch(download_url, 512000, 60, "PodkopTweaker", true)
    if not bytes then return { error = download_err and download_err:match("size limit") and "Archive too large" or "Failed to download archive", details = download_err } end
    local archive_ver, prepare_err, files = prepare_archive(bytes, tmp_dir, true)
    if not archive_ver then return { error = "Invalid archive", details = prepare_err } end

    if not force and not LIB.version_lt(VERSION, archive_ver) then
        cleanup_tmp(tmp_dir)
        return { error = "Archive version is not newer than installed" }
    end

    local copied, apply_err = apply_extracted(tmp_dir, tmp_dir, true, files)
    if apply_err then return { success = false, error = "Update application failed", details = apply_err, files_copied = copied, staging_retained = true } end
    os.remove(CHECK_CACHE_FILE)

    return {
        success = true,
        new_version = archive_ver,
        files_copied = copied
    }
end

function M.valid_git_url(url)
    if not NET.valid_url(url, true) or url:find("..", 1, true) then return false end
    return url:match("^https://github%.com/InsaniaQuon/luci%-app%-podkop%-tweaker/releases/download/v?%d+%.%d+%.%d+[a-zA-Z0-9_.%-]*/[a-zA-Z0-9_.%-]+%.tar%.gz$") ~= nil
end

return M
