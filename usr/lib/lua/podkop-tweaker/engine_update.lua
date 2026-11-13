-- Podkop Tweaker | v4.13.0 | 01.11.2026 | podkop-engine release check and package update
-- Author: InsaniaQuon
-- Talks only to api.github.com/github.com of the podkop-net/podkop-engine
-- repository. No mirror endpoints and no device identifiers are involved:
-- the requests carry the shared PodkopTweaker user agent only.

local LIB = require("podkop-tweaker.lib")
local SRV = require("podkop-tweaker.services")
local NET = require("podkop-tweaker.net")
local S = require("pt-subs-lib")

local M = {}
M.CHECK_CACHE = "/tmp/pt_engine_check.json"
M.CHECK_TTL = 86400
-- The releases.atom feed carries the complete patch list in every release
-- body (~30 KB per release, 10 entries ≈ 300 KB observed 02.11.2026), so the
-- atom bound must be far above a "small feed" assumption.
M.ATOM_LIMIT = 1048576
M.STAGE_PATH = "/tmp/pt-engine.apk"
M.MAX_APK = 33554432
M.DOWNLOAD_TIMEOUT = 480
M.DOWNLOAD_PREFIX = "https://github.com/podkop-net/podkop-engine/releases/download/"
M.API_LATEST = "https://api.github.com/repos/podkop-net/podkop-engine/releases/latest"
M.API_TAG_PREFIX = "https://api.github.com/repos/podkop-net/podkop-engine/releases/tags/"
M.ATOM_URL = "https://github.com/podkop-net/podkop-engine/releases.atom"

-- Installed binary facts. The flavor comes from the Tags line the engine
-- build prints (a full build carries podkop_slim AND podkop_full, so the
-- full marker is checked first); the package arch comes from the installed
-- package line, because apk --print-arch reports the alpine arch instead.
local function parse_version_output(output)
    if type(output) ~= "string" then return nil end
    local version = output:match("sing%-box version (%S+)")
    if not version then return nil end
    local tags = output:match("\nTags:%s*([^\r\n]+)")
    if tags then tags = tags:gsub("^%s+", ""):gsub("%s+$", "") end
    local flavor
    if tags then
        if tags:find("podkop_full", 1, true) then flavor = "full"
        elseif tags:find("podkop_slim", 1, true) then flavor = "slim" end
    end
    return { version = version, flavor = flavor }
end

function M.installed()
    local ok, output = SRV.exec_bounded("sing-box version", { timeout = 3 })
    if not ok then return { present = false } end
    local parsed = parse_version_output(output)
    if not parsed or not parsed.flavor or not LIB.parse_engine_version(parsed.version) then
        return { present = false }
    end
    local facts = { present = true, version = parsed.version, flavor = parsed.flavor }
    local aok, aoutput = SRV.exec_bounded("apk list --installed podkop-engine podkop-engine-full", { timeout = 3 })
    if aok and type(aoutput) == "string" then
        for line in aoutput:gmatch("[^\r\n]+") do
            local pkg, arch = line:match("^(podkop%-engine%S*)%s+(%S+)")
            if pkg and pkg:match("^podkop%-engine%-?") and arch and arch ~= "noarch" then
                facts.arch = arch
                break
            end
        end
    end
    return facts
end

local function read_cache()
    local fd = io.open(M.CHECK_CACHE, "r")
    if not fd then return nil end
    local raw = fd:read("*a")
    fd:close()
    local cache = S.json_parse(raw)
    return type(cache) == "table" and cache or nil
end

local function write_cache(entry)
    local str = S.json_stringify(entry)
    if not str then return end
    local fd = io.open(M.CHECK_CACHE, "w")
    if not fd then return end
    fd:write(str)
    fd:close()
end

-- Picks this device's asset from one GitHub release. The canonical download
-- prefix gate and the mandatory sha256 digest are hard requirements; a
-- release without them is not offered.
local function asset_from_release(release, facts)
    if type(release) ~= "table" or release.prerelease == true then return nil end
    if type(release.tag_name) ~= "string" or type(facts.arch) ~= "string" then return nil end
    local tagver = LIB.engine_version_tag(release.tag_name)
    if not tagver then return nil end
    local pkg = facts.flavor == "full" and "podkop-engine-full" or "podkop-engine"
    local want = pkg .. "_" .. tagver .. "_openwrt_" .. facts.arch .. ".apk"
    for _, asset in ipairs(type(release.assets) == "table" and release.assets or {}) do
        if type(asset) == "table" and asset.name == want then
            local digest = type(asset.digest) == "string"
                and asset.digest:match("^sha256:([0-9a-fA-F]+)$") or nil
            local url = type(asset.browser_download_url) == "string"
                and asset.browser_download_url or nil
            if url and url:sub(1, #M.DOWNLOAD_PREFIX) ~= M.DOWNLOAD_PREFIX then url = nil end
            local size = tonumber(asset.size)
            if digest and url and size and size > 0 and size <= M.MAX_APK then
                return {
                    tag = release.tag_name,
                    version = LIB.engine_version_display(release.tag_name),
                    name = want, url = url, size = size, sha256 = digest:lower()
                }
            end
            return nil
        end
    end
    return nil
end

-- The download honours the podkop list-download routing: through the local
-- mixed inbound when podkop.settings.download_lists_via_proxy is enabled.
-- The same detour applies to github.com requests in check()/find_rollback:
-- github.com (the atom feed) may be unreachable directly while api.github.com
-- keeps working, which previously made the rollback candidate silently absent.
local function mixed_detour_port()
    local uci = require("luci.model.uci").cursor()
    if uci:get("podkop", "settings", "download_lists_via_proxy") ~= "1" then return nil end
    local DIAG = require("podkop-tweaker.diag")
    for _, inbound in ipairs(DIAG.get_singbox_inbounds()) do
        if inbound.type == "mixed" and inbound.port then
            return math.floor(tonumber(inbound.port) or 0)
        end
    end
    return nil
end

local function github_detour()
    local port = mixed_detour_port()
    if not port then return nil end
    return "http://127.0.0.1:" .. port
end

-- Rollback candidate: the newest release tag whose full engine version is
-- strictly lower than the installed one (the revision counter resets with
-- every new base, so the full version decides). Network failures are told
-- apart from "no older tag exists": the caller caches a short-TTL entry so
-- the next System Info refresh (with the mixed detour back after an engine
-- restart) redoes the discovery instead of losing the Downgrade action
-- silently for the full 24 h TTL (race observed live r21->r24, 12.11.2026).
local function find_rollback(facts)
    local atom = NET.fetch(M.ATOM_URL, M.ATOM_LIMIT, 20, "PodkopTweaker", true, github_detour())
    if type(atom) ~= "string" then return nil, "atom" end
    local best, seen = nil, {}
    for tag in atom:gmatch("v%d+%.%d+%.%d+%-r%d+") do
        if not seen[tag] then
            seen[tag] = true
            if LIB.engine_version_lt(tag, facts.version) then
                if not best or LIB.engine_version_lt(best, tag) then best = tag end
            end
        end
    end
    if not best then return nil, nil end
    local raw = NET.fetch(M.API_TAG_PREFIX .. best, 262144, 20, "PodkopTweaker", true)
    local release = type(raw) == "string" and S.json_parse(raw) or nil
    if type(release) ~= "table" then return nil, "tag" end
    local asset = asset_from_release(release, facts)
    if not asset then return nil, "tag" end
    return asset, nil
end

-- A rollback-discovery failure keeps the cache fresh only briefly: the next
-- system_info/status read retries the whole check once the detour answers.
M.ROLLBACK_RETRY_TTL = 120

function M.check(force)
    local facts = M.installed()
    if not facts.present then return { installed = false } end
    local base = {
        installed = true, version = facts.version,
        flavor = facts.flavor, arch = facts.arch
    }
    if not force then
        local cached = read_cache()
        if cached and type(cached.checked_at) == "number"
            and cached.version == facts.version then
            local ttl = M.CHECK_TTL
            -- a failed rollback discovery is transient (usually the mixed
            -- detour still restarting): retry the whole check within 120 s
            if cached.rollback_error then ttl = M.ROLLBACK_RETRY_TTL end
            if (os.time() - cached.checked_at) < ttl then
                return cached
            end
        end
    end
    local raw, err = NET.fetch(M.API_LATEST, 262144, 20, "PodkopTweaker", true)
    local release = type(raw) == "string" and S.json_parse(raw) or nil
    if type(release) ~= "table" then
        base.error = "Cannot read the engine release facts"
        base.details = err or "invalid release response"
        return base
    end
    local latest = asset_from_release(release, facts)
    if not latest then
        base.error = "No engine release asset matches this device"
        return base
    end
    base.latest = latest
    base.update_available = LIB.engine_version_lt(facts.version, latest.version)
    local rollback, rb_err = find_rollback(facts)
    if rollback then base.rollback = rollback else base.rollback_error = rb_err end
    base.checked_at = os.time()
    write_cache(base)
    return base
end

-- Flattened view for the System Information row and the check summary.
function M.status(force)
    local info = M.check(force)
    return {
        installed = info.installed == true,
        version = info.version, flavor = info.flavor, arch = info.arch,
        update_available = info.update_available == true,
        latest_version = type(info.latest) == "table" and info.latest.version or nil,
        rollback_version = type(info.rollback) == "table" and info.rollback.version or nil,
        error = info.error, details = info.details
    }
end

function M.apply(target)
    if target ~= "latest" and target ~= "rollback" and target ~= "switch" then
        return { success = false, error = "Invalid target" }
    end
    local facts = M.installed()
    if not facts.present then
        return { success = false, error = "Podkop engine is not installed" }
    end
    local desc
    local flavor_target = nil
    local remove_pkg = nil
    if target == "switch" then
        -- A switch is a pure flavor change at the SAME release tag: the asset
        -- comes from the installed tag's release, for the opposite flavor.
        flavor_target = facts.flavor == "full" and "slim" or "full"
        local tag = "v" .. LIB.engine_version_tag(facts.version)
        local raw, err = NET.fetch(M.API_TAG_PREFIX .. tag, 262144, 20, "PodkopTweaker", true)
        local release = type(raw) == "string" and S.json_parse(raw) or nil
        if type(release) ~= "table" then
            return { success = false, error = "Cannot read the installed engine release facts",
                details = err or "invalid release response" }
        end
        desc = asset_from_release(release, { flavor = flavor_target, arch = facts.arch })
        if not desc then
            return { success = false, error = "No opposite-flavor engine asset matches this device" }
        end
        if desc.version ~= facts.version then
            return { success = false, error = "Switch release asset does not preserve the installed version" }
        end
        remove_pkg = flavor_target == "full" and "podkop-engine" or "podkop-engine-full"
    else
        local cache = read_cache()
        if type(cache) ~= "table" or type(cache.checked_at) ~= "number" then
            return { success = false, error = "Engine release facts are not checked yet" }
        end
        desc = cache[target]
        if type(desc) ~= "table" or type(desc.url) ~= "string"
            or type(desc.sha256) ~= "string" or type(desc.size) ~= "number" then
            return { success = false, error = target == "rollback"
                and "No rollback release is available for this device"
                or "No engine release facts for an update" }
        end
        if target == "latest" and cache.update_available ~= true then
            return { success = false, error = "No newer engine release is available" }
        end
        if target == "rollback" and not LIB.engine_version_lt(desc.version, facts.version) then
            return { success = false, error = "Rollback target is not older than the installed engine" }
        end
    end
    if desc.url:sub(1, #M.DOWNLOAD_PREFIX) ~= M.DOWNLOAD_PREFIX then
        return { success = false, error = "Refusing a non-canonical engine download URL" }
    end

    local detour_port = mixed_detour_port()
    local response = {
        target = target,
        version_expected = desc.version,
        flavor_before = facts.flavor,
        detour = detour_port and ("127.0.0.1:" .. detour_port) or "direct"
    }

    -- Download outside any resource lock; staging only, nothing is mutated.
    local curl = "curl --disable --silent --show-error --fail --location --globoff" ..
        " --max-redirs 5 --max-time " .. tostring(M.DOWNLOAD_TIMEOUT) ..
        " --max-filesize " .. tostring(M.MAX_APK) ..
        " --proto " .. LIB.shell_escape("=https") ..
        " --proto-redir " .. LIB.shell_escape("=https") ..
        " -A " .. LIB.shell_escape("PodkopTweaker")
    if detour_port then
        curl = curl .. " -x " .. LIB.shell_escape("http://127.0.0.1:" .. detour_port)
    end
    curl = curl .. " -o " .. LIB.shell_escape(M.STAGE_PATH) ..
        " " .. LIB.shell_escape(desc.url) .. " 2>&1"
    local dok, ddetails, dcode = SRV.exec_checked(curl)
    if not dok then
        os.remove(M.STAGE_PATH)
        response.success = false
        response.error = dcode ~= nil and "Engine package download failed"
            or "Engine package download outcome is unknown"
        response.command_result_known = dcode ~= nil
        response.command_exit_code = dcode
        response.unknown = dcode == nil or nil
        response.details = ddetails
        return response
    end

    -- Size and digest must both match the pinned release facts before apk
    -- is invoked; a mismatch aborts the update without touching packages.
    local sok, sdetails = SRV.exec_checked("wc -c < " .. LIB.shell_escape(M.STAGE_PATH))
    local size = sok and tonumber((sdetails or ""):match("(%d+)")) or nil
    if not sok or size ~= desc.size then
        os.remove(M.STAGE_PATH)
        response.success = false
        response.error = "Downloaded engine package size mismatch"
        response.expected_size = desc.size
        response.actual_size = size
        response.details = sdetails
        return response
    end
    local hok, hdetails = SRV.exec_checked("sha256sum " .. LIB.shell_escape(M.STAGE_PATH))
    local hash = hok and (hdetails or ""):match("^%s*([0-9a-fA-F]+)") or nil
    if not hok or not hash or hash:lower() ~= desc.sha256 then
        os.remove(M.STAGE_PATH)
        response.success = false
        response.error = "Engine package digest mismatch"
        response.expected_sha256 = desc.sha256
        response.actual_sha256 = hash and hash:lower() or nil
        response.details = hdetails
        return response
    end
    response.download = { size = size, sha256_verified = true }

    -- Short mutation phase under the podkop lock: package install plus the
    -- checked podkop restart with full prior/new-instance evidence. The
    -- closure extends the same response table, so the pre-lock download
    -- facts survive the lock phase. A flavor switch replaces the opposite
    -- package inside the same apk transaction (documented engine syntax).
    local apk_cmd = "apk add --allow-untrusted " .. LIB.shell_escape(M.STAGE_PATH)
    if remove_pkg then
        apk_cmd = apk_cmd .. " " .. LIB.shell_escape("!" .. remove_pkg)
    end
    local outcome, lock_err, uncertain = SRV.with_lock("podkop", function()
        response.applied = false
        local aok, adetails, acode = SRV.exec_checked(apk_cmd .. " 2>&1")
        response.command_result_known = acode ~= nil
        response.command_exit_code = acode
        response.apk_details = adetails
        if not aok then
            response.success = false
            response.error = acode ~= nil and "apk installation of the engine package failed"
                or "apk installation outcome is unknown"
            response.unknown = acode == nil or nil
            return response
        end
        response.applied = true
        response.restart = SRV.restart_service(SRV.ops.podkop)
        response.success = response.restart.success == true
        if not response.success then
            response.error = response.restart.error or "Podkop restart failed after the engine update"
        end
        return response
    end)
    os.remove(M.STAGE_PATH)
    if not outcome then
        response.success = false
        response.error = "Cannot acquire the podkop lock"
        response.details = tostring(lock_err)
        response.uncertain = uncertain or nil
        return response
    end
    if outcome.success then
        local after = M.installed()
        outcome.version_after = after.version
        outcome.version_match = after.version == desc.version
        if flavor_target then
            outcome.flavor_after = after.flavor
            outcome.flavor_match = after.flavor == flavor_target
            if not (outcome.version_match and outcome.flavor_match) then
                outcome.verification_required = true
            end
        elseif not outcome.version_match then
            outcome.verification_required = true
        end
        os.remove(M.CHECK_CACHE)
    end
    return outcome
end

return M
