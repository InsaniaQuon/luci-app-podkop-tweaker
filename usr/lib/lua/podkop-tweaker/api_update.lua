-- Podkop Tweaker | v4.2.0 | 23.08.2026 | V2 pure handlers: args in -> response table out; HTTP layer moved to controller adapter

local SRV = require("podkop-tweaker.services")
local LIB = require("podkop-tweaker.lib")
local S = require("pt-subs-lib")

local M = {}

local GIT_REPO = "InsaniaQuon/luci-app-podkop-tweaker"
local GIT_API_URL = "https://api.github.com/repos/" .. GIT_REPO .. "/releases/latest"
local CHECK_CACHE_FILE = "/tmp/tweaker_check_cache.json"
local CHECK_CACHE_TTL = 900

local VERSION = ""

function M.init(version)
    VERSION = version or ""
end

function M.get_version()
    return VERSION
end

function M.cached_latest()
    local latest = nil
    local cache_fd = io.open(CHECK_CACHE_FILE, "r")
    if cache_fd then
        local raw_cache = cache_fd:read("*a")
        cache_fd:close()
        local tweaker_cache = nil
        pcall(function()
            local json = require("luci.jsonc")
            tweaker_cache = json.parse(raw_cache)
        end)
        if tweaker_cache and tweaker_cache.latest_version and tweaker_cache.cached_at then
            local elapsed = os.time() - tweaker_cache.cached_at
            if elapsed < CHECK_CACHE_TTL then
                latest = tweaker_cache.latest_version
            end
        end
    end
    return latest
end

local function extract_version_from_file(dir_prefix)
    local ctrl_path = dir_prefix .. "/usr/lib/lua/luci/controller/podkop-tweaker.lua"
    local fd = io.open(ctrl_path, "r")
    if not fd then return nil end
    local ver = nil
    for line in fd:lines() do
        ver = line:match('APP_VERSION%s*=%s*"([^"]+)"')
        if ver then break end
    end
    fd:close()
    return ver
end

local function validate_archive_structure(dir_prefix, relaxed)
    local sys = require("luci.sys")
    local find_cmd = "find '" .. dir_prefix .. "' -type f \\! -type l 2>/dev/null"
    local raw = sys.exec(find_cmd)
    if not raw or raw == "" then return false, "Archive is empty" end

    local prefix_len = #dir_prefix + 1
    local count = 0
    for line in raw:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then
            local rel = line:sub(prefix_len):match("^/?(.*)")
            if rel ~= "" then
                count = count + 1
                if not S._is_valid_update_path(rel, relaxed) then
                    return false, "file not allowed"
                end
            end
        end
    end

    if count == 0 then return false, "No files found in archive" end

    local ctrl_rel = "usr/lib/lua/luci/controller/podkop-tweaker.lua"
    local ctrl_full = dir_prefix .. "/" .. ctrl_rel
    local st = io.open(ctrl_full, "r")
    if not st then return false, "Controller file not found in archive" end
    st:close()

    return true, count .. " file(s) validated"
end

function M.upload(file_data_b64, file_name)
    local sys = require("luci.sys")

    if file_data_b64 == "" then
        return { error = "No file uploaded" }
    end

    local file_data = S.b64decode(file_data_b64)
    if not file_data or file_data == "" then
        return { error = "Invalid archive" }
    end

    if #file_data > 128000 then
        return { error = "Invalid archive" }
    end

    if not file_name:match("luci%-app%-podkop%-tweaker%-v.+%.tar%.gz$") then
        return { error = "Invalid archive" }
    end

    local tmp_dir = "/tmp/pt-update"
    sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
    sys.exec("mkdir -p " .. tmp_dir .. " 2>/dev/null")

    local archive_path = tmp_dir .. "/upload.tar.gz"
    local fd = io.open(archive_path, "wb")
    if not fd then
        return { error = "Invalid archive" }
    end
    fd:write(file_data)
    fd:close()

    sys.exec("cd " .. tmp_dir .. " && tar -xzf upload.tar.gz 2>&1")
    sys.exec("rm -f " .. archive_path .. " 2>/dev/null")

    local extract_dir = tmp_dir
    local stat = io.open(extract_dir .. "/usr/lib/lua/luci/controller/podkop-tweaker.lua", "r")
    if not stat then
        sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
        return { error = "Invalid archive" }
    end
    stat:close()

    local valid, verr = validate_archive_structure(extract_dir, false)
    if not valid then
        sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
        return { error = "Invalid archive" }
    end

    local archive_ver = extract_version_from_file(extract_dir)
    if not archive_ver then
        sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
        return { error = "Invalid archive" }
    end

    local can_update = LIB.version_lt(VERSION, archive_ver)
    local same_version = not LIB.version_lt(VERSION, archive_ver)
        and not LIB.version_lt(archive_ver, VERSION)

    return {
        success = true,
        current_version = VERSION,
        archive_version = archive_ver,
        can_update = can_update,
        same_version = same_version
    }
end

function M.apply()
    local sys = require("luci.sys")
    local nixio = require("nixio")

    local tmp_dir = "/tmp/pt-update"
    local extract_dir = tmp_dir

    if not nixio.fs.stat(extract_dir) then
        return { error = "No archive uploaded" }
    end

    local archive_ver = extract_version_from_file(extract_dir)
    if not archive_ver then
        sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
        return { error = "Invalid archive" }
    end

    if not LIB.version_lt(VERSION, archive_ver) then
        return { error = "Archive version is not newer than installed" }
    end

    local copied = S.apply_files_from_dir(extract_dir, false)

    sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
    sys.exec("rm -rf /tmp/luci-modulecache 2>/dev/null")
    sys.exec("nohup /etc/init.d/uhttpd restart >/dev/null 2>&1 &")

    return {
        success = true,
        new_version = archive_ver,
        files_copied = copied
    }
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

function M.check_update()
    local sys = require("luci.sys")

    local cache_fd = io.open(CHECK_CACHE_FILE, "r")
    if cache_fd then
        local cache_data = cache_fd:read("*a")
        cache_fd:close()
        local cache = S.json_parse(cache_data)
        if cache and cache.cached_at then
            local elapsed = os.time() - cache.cached_at
            if elapsed < CHECK_CACHE_TTL then
                return {
                    error = "rate_limited",
                    retry_after = CHECK_CACHE_TTL - elapsed
                }
            end
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
            if asset.browser_download_url then
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
        local cfd = io.open(CHECK_CACHE_FILE, "w")
        if cfd then
            cfd:write(cache_str)
            cfd:close()
        end
    end

    return {
        current_version = VERSION,
        latest_version = latest_ver,
        update_available = update_available,
        download_url = download_url
    }
end

function M.git_update(download_url, force_raw)
    local sys = require("luci.sys")

    local force = force_raw == "1"

    if download_url == "" then
        return { error = "Download URL is required" }
    end
    if not download_url:match("^https://github%.com/InsaniaQuon/luci%-app%-podkop%-tweaker/") then
        return { error = "Invalid download URL" }
    end

    local tmp_dir = "/tmp/pt-git-update"
    sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
    sys.exec("mkdir -p " .. tmp_dir .. " 2>/dev/null")

    local archive_path = tmp_dir .. "/download.tar.gz"
    sys.exec("curl -sL -m 60 -o " .. archive_path .. " " .. S.shell_escape(download_url) .. " 2>/dev/null")

    local st = io.open(archive_path, "r")
    if not st then
        sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
        return { error = "Failed to download archive" }
    end
    local archive_size = st:seek("end")
    st:close()
    if archive_size > 512000 then
        sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
        return { error = "Archive too large" }
    end

    sys.exec("cd " .. tmp_dir .. " && tar -xzf download.tar.gz 2>&1")
    sys.exec("rm -f " .. archive_path .. " 2>/dev/null")

    local extract_dir = tmp_dir
    local ctrl = io.open(extract_dir .. "/usr/lib/lua/luci/controller/podkop-tweaker.lua", "r")
    if not ctrl then
        sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
        return { error = "Invalid archive" }
    end
    ctrl:close()

    local valid, verr = validate_archive_structure(extract_dir, true)
    if not valid then
        sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
        return { error = "Invalid archive" }
    end

    local archive_ver = extract_version_from_file(extract_dir)
    if not archive_ver then
        sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
        return { error = "Invalid archive" }
    end

    if not force and not LIB.version_lt(VERSION, archive_ver) then
        sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
        return { error = "Archive version is not newer than installed" }
    end

    local copied = S.apply_files_from_dir(extract_dir, true)

    sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
    sys.exec("rm -rf /tmp/luci-modulecache 2>/dev/null")
    os.remove(CHECK_CACHE_FILE)

    sys.exec("nohup /etc/init.d/uhttpd restart >/dev/null 2>&1 &")

    return {
        success = true,
        new_version = archive_ver,
        files_copied = copied
    }
end

return M
