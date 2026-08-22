-- Podkop Tweaker | Tweaker self-update API handlers (local archive + GitHub releases)
-- Author: InsaniaQuon

local H = require("podkop-tweaker.http")
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

function M.upload()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    H.no_cache()

    local ok, err = pcall(function()
        local file_data_b64 = http.formvalue("file_data") or ""
        local file_name = http.formvalue("file_name") or ""

        if file_data_b64 == "" then
            http.write_json({ error = "No file uploaded" })
            return
        end

        local file_data = S.b64decode(file_data_b64)
        if not file_data or file_data == "" then
            http.write_json({ error = "Invalid archive" })
            return
        end

        if #file_data > 128000 then
            http.write_json({ error = "Invalid archive" })
            return
        end

        if not file_name:match("luci%-app%-podkop%-tweaker%-v.+%.tar%.gz$") then
            http.write_json({ error = "Invalid archive" })
            return
        end

        local tmp_dir = "/tmp/pt-update"
        sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
        sys.exec("mkdir -p " .. tmp_dir .. " 2>/dev/null")

        local archive_path = tmp_dir .. "/upload.tar.gz"
        local fd = io.open(archive_path, "wb")
        if not fd then
            http.write_json({ error = "Invalid archive" })
            return
        end
        fd:write(file_data)
        fd:close()

        sys.exec("cd " .. tmp_dir .. " && tar -xzf upload.tar.gz 2>&1")
        sys.exec("rm -f " .. archive_path .. " 2>/dev/null")

        local extract_dir = tmp_dir
        local stat = io.open(extract_dir .. "/usr/lib/lua/luci/controller/podkop-tweaker.lua", "r")
        if not stat then
            http.write_json({ error = "Invalid archive" })
            sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
            return
        end
        stat:close()

        local valid, verr = validate_archive_structure(extract_dir, false)
        if not valid then
            http.write_json({ error = "Invalid archive" })
            sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
            return
        end

        local archive_ver = extract_version_from_file(extract_dir)
        if not archive_ver then
            http.write_json({ error = "Invalid archive" })
            sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
            return
        end

        local can_update = LIB.version_lt(VERSION, archive_ver)
        local same_version = not LIB.version_lt(VERSION, archive_ver)
            and not LIB.version_lt(archive_ver, VERSION)

        http.write_json({
            success = true,
            current_version = VERSION,
            archive_version = archive_ver,
            can_update = can_update,
            same_version = same_version
        })
    end)

    if not ok then
        http.prepare_content("application/json")
        http.write_json({ error = "Internal error" })
    end
end

function M.apply()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    local nixio = require("nixio")
    http.prepare_content("application/json")
    H.no_cache()

    local ok, err = pcall(function()
        local tmp_dir = "/tmp/pt-update"
        local extract_dir = tmp_dir

        if not nixio.fs.stat(extract_dir) then
            http.write_json({ error = "No archive uploaded" })
            return
        end

        local archive_ver = extract_version_from_file(extract_dir)
        if not archive_ver then
            http.write_json({ error = "Invalid archive" })
            sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
            return
        end

        if not LIB.version_lt(VERSION, archive_ver) then
            http.write_json({ error = "Archive version is not newer than installed" })
            return
        end

        local copied = S.apply_files_from_dir(extract_dir, false)

        sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
        sys.exec("rm -rf /tmp/luci-modulecache 2>/dev/null")
        sys.exec("nohup /etc/init.d/uhttpd restart >/dev/null 2>&1 &")

        http.write_json({
            success = true,
            new_version = archive_ver,
            files_copied = copied
        })
    end)

    if not ok then
        http.prepare_content("application/json")
        http.write_json({ error = "Internal error" })
    end
end

function M.clear_cache()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    H.no_cache()

    os.execute("rm -rf /tmp/luci-* 2>/dev/null")
    os.remove(CHECK_CACHE_FILE)

    sys.exec("nohup /etc/init.d/uhttpd restart >/dev/null 2>&1 &")

    http.write_json({ success = true })
end

function M.read_log()
    local http = require("luci.http")
    http.prepare_content("application/json")
    H.no_cache()

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

    local json = require("luci.jsonc")
    local resp = '{"lines":['
    for i = 1, n do
        if i > 1 then resp = resp .. ',' end
        resp = resp .. json.stringify(lines[i])
    end
    resp = resp .. ']}'
    http.write(resp)
end

function M.check_update()
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    H.no_cache()

    local cache_fd = io.open(CHECK_CACHE_FILE, "r")
    if cache_fd then
        local cache_data = cache_fd:read("*a")
        cache_fd:close()
        local cache = S.json_parse(cache_data)
        if cache and cache.cached_at then
            local elapsed = os.time() - cache.cached_at
            if elapsed < CHECK_CACHE_TTL then
                http.write_json({
                    error = "rate_limited",
                    retry_after = CHECK_CACHE_TTL - elapsed
                })
                return
            end
        end
    end

    local raw = sys.exec("curl -sL -m 10 -A 'PodkopTweaker' '" .. GIT_API_URL .. "' 2>/dev/null")
    if not raw or raw == "" then
        http.write_json({ error = "Failed to connect to GitHub" })
        return
    end

    local release = S.json_parse(raw)
    if not release then
        http.write_json({ error = "Failed to parse GitHub response" })
        return
    end

    if release.message and (release.message:match("rate limit") or release.message:match("API rate")) then
        http.write_json({ error = "GitHub API rate limit exceeded" })
        return
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

    http.write_json({
        current_version = VERSION,
        latest_version = latest_ver,
        update_available = update_available,
        download_url = download_url
    })
end

function M.git_update()
    if not H.verify_csrf() then return end
    local http = require("luci.http")
    local sys = require("luci.sys")
    http.prepare_content("application/json")
    H.no_cache()

    local ok, err = pcall(function()
        local download_url = http.formvalue("download_url") or ""
        local force = http.formvalue("force") == "1"

        if download_url == "" then
            http.write_json({ error = "Download URL is required" })
            return
        end
        if not download_url:match("^https://github%.com/InsaniaQuon/luci%-app%-podkop%-tweaker/") then
            http.write_json({ error = "Invalid download URL" })
            return
        end

        local tmp_dir = "/tmp/pt-git-update"
        sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
        sys.exec("mkdir -p " .. tmp_dir .. " 2>/dev/null")

        local archive_path = tmp_dir .. "/download.tar.gz"
        sys.exec("curl -sL -m 60 -o " .. archive_path .. " " .. S.shell_escape(download_url) .. " 2>/dev/null")

        local st = io.open(archive_path, "r")
        if not st then
            http.write_json({ error = "Failed to download archive" })
            sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
            return
        end
        local archive_size = st:seek("end")
        st:close()
        if archive_size > 512000 then
            http.write_json({ error = "Archive too large" })
            sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
            return
        end

        sys.exec("cd " .. tmp_dir .. " && tar -xzf download.tar.gz 2>&1")
        sys.exec("rm -f " .. archive_path .. " 2>/dev/null")

        local extract_dir = tmp_dir
        local ctrl = io.open(extract_dir .. "/usr/lib/lua/luci/controller/podkop-tweaker.lua", "r")
        if not ctrl then
            http.write_json({ error = "Invalid archive" })
            sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
            return
        end
        ctrl:close()

        local valid, verr = validate_archive_structure(extract_dir, true)
        if not valid then
            http.write_json({ error = "Invalid archive" })
            sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
            return
        end

        local archive_ver = extract_version_from_file(extract_dir)
        if not archive_ver then
            http.write_json({ error = "Invalid archive" })
            sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
            return
        end

        if not force and not LIB.version_lt(VERSION, archive_ver) then
            http.write_json({ error = "Archive version is not newer than installed" })
            sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
            return
        end

        local copied = S.apply_files_from_dir(extract_dir, true)

        sys.exec("rm -rf " .. tmp_dir .. " 2>/dev/null")
        sys.exec("rm -rf /tmp/luci-modulecache 2>/dev/null")
        os.remove(CHECK_CACHE_FILE)

        sys.exec("nohup /etc/init.d/uhttpd restart >/dev/null 2>&1 &")

        http.write_json({
            success = true,
            new_version = archive_ver,
            files_copied = copied
        })
    end)

    if not ok then
        http.prepare_content("application/json")
        http.write_json({ error = "Internal error" })
    end
end

return M
