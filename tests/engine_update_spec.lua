-- engine_update_spec | v1.1.0 | 13.11.2026 | + rollback-discovery race (short retry TTL, atom-fail marker)

package.path = "./usr/lib/lua/?.lua;./tests/?.lua;" .. package.path

local H = require("pt_harness")

local DIGEST = string.rep("aa", 32)
local BAD_DIGEST = string.rep("bb", 32)

local SB_R20 = "sing-box version 1.14.4-pdk-r20\n\nEnvironment: go1.26.8 linux/arm64\n" ..
    "Tags: with_quic,with_utls,with_clash_api,podkop_slim\nCGO: enabled\n" ..
    "Features: urltest.fallbacks,urltest.download_url,transport.xhttp,tools.decode-link,tls.utls-fallback\n"
local SB_R21 = "sing-box version 1.14.4-pdk-r21\n\nTags: with_quic,podkop_slim\nFeatures: tools.decode-link\n"
local SB_R19 = "sing-box version 1.14.4-pdk-r19\n\nTags: with_quic,podkop_slim\nFeatures: tools.decode-link\n"
local SB_FULL = "sing-box version 1.14.4-pdk-r20\n\nTags: with_quic,podkop_slim,podkop_full\nFeatures: tools.decode-link\n"
local SB_UPSTREAM = "sing-box version 1.13.21\n\nTags: with_gvisor,with_quic\nCGO: enabled\n"

local APK_SLIM = "podkop-engine-1.14.4-r20 aarch64_cortex-a53 {origin} (GPL-3.0.0-or-later) [installed]\n"
local APK_FULL = "podkop-engine-full-1.14.4-r20 aarch64_cortex-a53 {origin} (GPL-3.0.0-or-later) [installed]\n"

local ATOM = '<?xml version="1.0"?><feed>' ..
    '<entry><title>v1.14.4-r21</title></entry>' ..
    '<entry><title>v1.14.4-r20</title></entry>' ..
    '<entry><title>v1.14.4-r19</title></entry>' ..
    '<entry><title>v1.13.21-r18</title></entry>' ..
    '</feed>'

local function release_json(tag, flavor, size, digest)
    local tagver = tag:gsub("^v", "")
    local pkg = flavor == "full" and "podkop-engine-full" or "podkop-engine"
    local name = pkg .. "_" .. tagver .. "_openwrt_aarch64_cortex-a53.apk"
    return '{"tag_name":"' .. tag .. '","prerelease":false,"assets":[' ..
        '{"name":"' .. name .. '","size":' .. tostring(size) ..
        ',"digest":"sha256:' .. digest .. '"' ..
        ',"browser_download_url":"https://github.com/podkop-net/podkop-engine/releases/download/' ..
        tag .. '/' .. name .. '"}]}'
end

local PROCD_RUNNING = '{"sing-box":{"instances":{"sing-box.main":{"running":true,"pid":1796}}}}\nPT_EXIT:0\n'

local function proc_stat()
    local fields = {}
    for i = 1, 19 do fields[i] = tostring(i) end
    fields[20] = "8888"
    return "1796 (sing-box) " .. table.concat(fields, " ")
end

-- Deterministic environment for one scenario. The sing-box version output is
-- stateful: "apk add" flips it, which is what the post-install verification
-- reads back.
local function begin_engine(opts)
    opts = opts or {}
    local state = { sb = opts.singbox or SB_R20, apk = opts.apk_list or APK_SLIM }
    local pipes = {
        {
            match = function(cmd) return cmd:find("sing-box version", 1, true) ~= nil end,
            out = function() return state.sb .. "\nPT_EXIT:0\n" end
        },
        {
            match = "apk list --installed",
            out = function() return (state.apk or APK_SLIM) .. "\nPT_EXIT:0\n" end
        },
        { match = "releases/latest", out = function() return (opts.latest or "") .. "\nPT_CURL_EXIT:0\n" end },
        { match = "releases.atom", out = function()
            -- atom_fail: no output and no exit marker -> the fetch itself
            -- fails (network path), which is how a dead detour looks
            if opts.atom_fail then return "" end
            return (opts.atom or ATOM) .. "\nPT_CURL_EXIT:0\n"
        end },
        { match = "releases/tags/", out = function() return (opts.tag_release or "") .. "\nPT_CURL_EXIT:0\n" end },
        { match = "wc -c", out = tostring(opts.stage_size or 100) .. "\nPT_EXIT:0\n" },
        { match = "sha256sum", out = (opts.stage_sha or DIGEST) .. "  /tmp/pt-engine.apk\nPT_EXIT:0\n" },
        {
            match = "apk add",
            out = function()
                if opts.apk_fail then return "ERROR: triggered failure\nPT_EXIT:1\n" end
                if opts.after_singbox then state.sb = opts.after_singbox end
                if opts.after_apk_list then state.apk = opts.after_apk_list end
                return "OK: 80.9 MiB in 291 packages\nPT_EXIT:0\n"
            end
        },
        { match = "/etc/init.d/podkop restart", out = "\nPT_EXIT:0\n" },
        { match = function(cmd) return cmd:find("ubus", 1, true) and cmd:find("service list", 1, true) end, out = opts.procd or PROCD_RUNNING },
        -- The staged package download itself; kept last so the verification
        -- commands that mention the same path match their own responders.
        { match = "pt-engine.apk", out = "\nPT_EXIT:0\n" }
    }
    opts.popen = pipes
    H.begin(opts)
    H.vfs_write("/proc/1796/stat", proc_stat())
    return H.reload("podkop-tweaker.engine_update"), state
end

local function popen_cmds()
    return H.popen_cmds()
end

local function count_substring(sub)
    local count = 0
    for _, cmd in ipairs(popen_cmds()) do
        if cmd:find(sub, 1, true) then count = count + 1 end
    end
    return count
end

after_each(function()
    H.finish()
end)

describe("lib engine version helpers", function()
    local LIB = require("podkop-tweaker.lib")

    it("parses display and tag forms", function()
        assert.same({ 1, 14, 4, 20 }, LIB.parse_engine_version("1.14.4-pdk-r20"))
        assert.same({ 1, 14, 4, 20 }, LIB.parse_engine_version("v1.14.4-r20"))
        assert.is_nil(LIB.parse_engine_version("1.14.4"))
        assert.is_nil(LIB.parse_engine_version("1.13.21"))
        assert.is_nil(LIB.parse_engine_version("garbage"))
    end)

    it("compares the full version: a new base beats any revision counter", function()
        assert.is_true(LIB.engine_version_lt("1.13.21-r20", "1.14.4-r2"))
        assert.is_true(LIB.engine_version_lt("1.14.4-r20", "1.14.4-r21"))
        assert.is_false(LIB.engine_version_lt("1.14.4-r21", "1.14.4-r20"))
        assert.is_false(LIB.engine_version_lt("1.14.4-r20", "1.14.4-r20"))
        assert.is_true(LIB.engine_version_lt("1.14.4-r20", "1.15.0-r1"))
    end)

    it("round-trips display and tag forms", function()
        assert.equal("1.14.4-pdk-r20", LIB.engine_version_display("v1.14.4-r20"))
        assert.equal("1.14.4-r20", LIB.engine_version_tag("1.14.4-pdk-r20"))
    end)
end)

describe("engine_update.installed", function()
    it("upstream sing-box without podkop tags is not the engine", function()
        local ENG = begin_engine({ singbox = SB_UPSTREAM })
        local facts = ENG.installed()
        assert.is_false(facts.present)
        assert.equal(0, count_substring("releases/latest"), "no release requests without an engine")
    end)

    it("slim flavor and package arch are parsed", function()
        local ENG = begin_engine()
        local facts = ENG.installed()
        assert.is_true(facts.present)
        assert.equal("1.14.4-pdk-r20", facts.version)
        assert.equal("slim", facts.flavor)
        assert.equal("aarch64_cortex-a53", facts.arch)
    end)

    it("full flavor wins when both markers are printed", function()
        local ENG = begin_engine({ singbox = SB_FULL, apk_list = APK_FULL })
        local facts = ENG.installed()
        assert.equal("full", facts.flavor)
        assert.equal("aarch64_cortex-a53", facts.arch)
    end)
end)

describe("engine_update.check", function()
    it("newer latest and rollback candidate are both reported and cached", function()
        local ENG = begin_engine({
            latest = release_json("v1.14.4-r21", "slim", 100, DIGEST),
            tag_release = release_json("v1.14.4-r19", "slim", 90, DIGEST)
        })
        local info = ENG.check(true)
        assert.is_true(info.installed)
        assert.is_true(info.update_available)
        assert.equal("1.14.4-pdk-r21", info.latest.version)
        assert.equal("1.14.4-pdk-r19", info.rollback.version)
        assert.equal(DIGEST, info.latest.sha256)
        -- the cached decision serves the next non-forced read
        local calls = count_substring("releases/latest")
        assert.equal(1, calls)
        local cached = ENG.check(false)
        assert.is_true(cached.update_available)
        assert.equal(1, count_substring("releases/latest"), "cache hit issues no request")
    end)

    it("same version: no update, rollback still offered", function()
        local ENG = begin_engine({
            latest = release_json("v1.14.4-r20", "slim", 100, DIGEST),
            tag_release = release_json("v1.14.4-r19", "slim", 90, DIGEST)
        })
        local info = ENG.check(true)
        assert.is_false(info.update_available)
        assert.equal("1.14.4-pdk-r20", info.latest.version)
        assert.equal("1.14.4-pdk-r19", info.rollback.version)
    end)

    it("a failed atom fetch marks the cache and retries within the short TTL", function()
        -- the post-apply race: the fresh check runs while the mixed detour is
        -- still restarting, the atom fetch fails and the rollback candidate
        -- must not be lost silently for the full 24 h
        local opts = {
            latest = release_json("v1.14.4-r21", "slim", 100, DIGEST),
            tag_release = release_json("v1.14.4-r19", "slim", 90, DIGEST),
            atom_fail = true
        }
        local ENG = begin_engine(opts)
        local info = ENG.check(true)
        assert.is_nil(info.rollback)
        assert.equal("atom", info.rollback_error)
        assert.is_nil(ENG.status(false).rollback_version)
        -- backdate the marked cache past ROLLBACK_RETRY_TTL and let the
        -- detour answer again: the next non-forced read redoes the discovery
        local fd = io.open(ENG.CHECK_CACHE, "r")
        local raw = fd:read("*a")
        fd:close()
        raw = raw:gsub('("checked_at"%s*:%s*)%d+', '%1' .. tostring(os.time() - 300))
        H.vfs_write(ENG.CHECK_CACHE, raw)
        opts.atom_fail = nil
        local rechecked = ENG.check(false)
        assert.equal("1.14.4-pdk-r19", rechecked.rollback.version)
        assert.is_nil(rechecked.rollback_error)
        assert.equal(2, count_substring("releases/latest"), "the expired marked cache redoes the whole check")
    end)

    it("no older tag is a clean cache: the full TTL applies, no marker", function()
        local ENG = begin_engine({
            latest = release_json("v1.14.4-r20", "slim", 100, DIGEST),
            atom = '<?xml version="1.0"?><feed>' ..
                '<entry><title>v1.14.4-r21</title></entry>' ..
                '<entry><title>v1.14.4-r20</title></entry></feed>'
        })
        local info = ENG.check(true)
        assert.is_nil(info.rollback)
        assert.is_nil(info.rollback_error)
        local calls = count_substring("releases/latest")
        local cached = ENG.check(false)
        assert.is_nil(cached.rollback)
        assert.equal(calls, count_substring("releases/latest"), "a clean cache serves the full TTL")
    end)

    it("older latest release on another line is not an update", function()
        local ENG = begin_engine({
            latest = release_json("v1.13.21-r18", "slim", 100, DIGEST),
            tag_release = release_json("v1.14.4-r19", "slim", 90, DIGEST)
        })
        local info = ENG.check(true)
        assert.is_false(info.update_available)
    end)

    it("a failed release read is an explicit error without cache", function()
        local ENG = begin_engine({ latest = "" })
        local info = ENG.check(true)
        assert.is_true(info.installed)
        assert.is_truthy(info.error)
        local fd = io.open(ENG.CHECK_CACHE, "r")
        assert.is_nil(fd, "failed checks are not cached")
    end)

    it("a release without a digest or canonical URL is not offered", function()
        local broken = '{"tag_name":"v1.14.4-r21","prerelease":false,"assets":[' ..
            '{"name":"podkop-engine_1.14.4-r21_openwrt_aarch64_cortex-a53.apk","size":100,' ..
            '"browser_download_url":"https://example.com/evil.apk"}]}'
        local ENG = begin_engine({ latest = broken })
        local info = ENG.check(true)
        assert.is_truthy(info.error, "non-canonical asset is refused")
    end)

    it("status() flattens for the System Information row", function()
        local ENG = begin_engine({ latest = release_json("v1.14.4-r21", "slim", 100, DIGEST) })
        local s = ENG.status(false)
        assert.is_true(s.installed)
        assert.equal("1.14.4-pdk-r20", s.version)
        assert.equal("slim", s.flavor)
        assert.is_true(s.update_available)
        assert.equal("1.14.4-pdk-r21", s.latest_version)
        assert.is_nil(s.error)
    end)
end)

describe("engine_update.apply", function()
    it("invalid target and missing engine are explicit errors", function()
        local ENG = begin_engine()
        local r = ENG.apply("sideways")
        assert.is_false(r.success)
        assert.equal("Invalid target", r.error)
        H.finish()
        local ENG2 = begin_engine({ singbox = SB_UPSTREAM })
        local r2 = ENG2.apply("latest")
        assert.is_false(r2.success)
        assert.equal("Podkop engine is not installed", r2.error)
    end)

    it("requires checked release facts", function()
        local ENG = begin_engine()
        local r = ENG.apply("latest")
        assert.is_false(r.success)
        assert.equal("Engine release facts are not checked yet", r.error)
        assert.equal(0, count_substring("apk add"))
    end)

    it("update: verified download, apk install, checked restart, version proof", function()
        local ENG = begin_engine({
            latest = release_json("v1.14.4-r21", "slim", 100, DIGEST),
            tag_release = release_json("v1.14.4-r19", "slim", 90, DIGEST),
            after_singbox = SB_R21
        })
        ENG.check(true)
        local r = ENG.apply("latest")
        assert.is_true(r.success)
        assert.is_true(r.applied)
        assert.equal("1.14.4-pdk-r21", r.version_expected)
        assert.equal("1.14.4-pdk-r21", r.version_after)
        assert.is_true(r.version_match)
        assert.is_true(r.download.sha256_verified)
        assert.is_true(r.restart.restarting)
        assert.equal(0, r.command_exit_code)
        assert.equal("1796:8888", r.restart.previous_instance)
        assert.is_not_nil(popen_cmds()[1])
        assert.is_true(count_substring("apk add --allow-untrusted") >= 1)
        assert.is_nil(io.open(ENG.STAGE_PATH, "r"), "stage is cleaned after success")
        assert.is_nil(io.open(ENG.CHECK_CACHE, "r"), "cache is invalidated after success")
    end)

    it("rollback installs the strictly older release", function()
        local ENG = begin_engine({
            latest = release_json("v1.14.4-r20", "slim", 100, DIGEST),
            tag_release = release_json("v1.14.4-r19", "slim", 90, DIGEST),
            after_singbox = SB_R19,
            stage_size = 90
        })
        ENG.check(true)
        local r = ENG.apply("rollback")
        assert.is_true(r.success)
        assert.equal("rollback", r.target)
        assert.equal("1.14.4-pdk-r19", r.version_expected)
        assert.equal("1.14.4-pdk-r19", r.version_after)
        assert.is_true(r.version_match)
    end)

    it("digest mismatch aborts before apk and cleans the stage", function()
        local ENG = begin_engine({
            latest = release_json("v1.14.4-r21", "slim", 100, DIGEST),
            tag_release = release_json("v1.14.4-r19", "slim", 90, DIGEST),
            stage_sha = BAD_DIGEST
        })
        ENG.check(true)
        local r = ENG.apply("latest")
        assert.is_false(r.success)
        assert.equal("Engine package digest mismatch", r.error)
        assert.equal(DIGEST, r.expected_sha256)
        assert.equal(BAD_DIGEST, r.actual_sha256)
        assert.equal(0, count_substring("apk add"), "a bad digest never reaches apk")
        assert.is_nil(io.open(ENG.STAGE_PATH, "r"))
    end)

    it("size mismatch aborts before apk", function()
        local ENG = begin_engine({
            latest = release_json("v1.14.4-r21", "slim", 100, DIGEST),
            tag_release = release_json("v1.14.4-r19", "slim", 90, DIGEST),
            stage_size = 999
        })
        ENG.check(true)
        local r = ENG.apply("latest")
        assert.is_false(r.success)
        assert.equal("Downloaded engine package size mismatch", r.error)
        assert.equal(100, r.expected_size)
        assert.equal(999, r.actual_size)
        assert.equal(0, count_substring("apk add"))
    end)

    it("apk failure keeps evidence and requests no restart", function()
        local ENG = begin_engine({
            latest = release_json("v1.14.4-r21", "slim", 100, DIGEST),
            tag_release = release_json("v1.14.4-r19", "slim", 90, DIGEST),
            apk_fail = true
        })
        ENG.check(true)
        local r = ENG.apply("latest")
        assert.is_false(r.success)
        assert.is_false(r.applied)
        assert.equal(1, r.command_exit_code)
        assert.is_truthy(r.apk_details)
        assert.equal(0, count_substring("/etc/init.d/podkop restart"), "failed apk requests no restart")
        assert.is_nil(io.open(ENG.STAGE_PATH, "r"))
    end)

    it("download honours podkop list-download routing through the mixed inbound", function()
        local ENG = begin_engine({
            latest = release_json("v1.14.4-r21", "slim", 100, DIGEST),
            tag_release = release_json("v1.14.4-r19", "slim", 90, DIGEST),
            after_singbox = SB_R21,
            uci = {
                podkop = {
                    H.sec("settings", "settings", { download_lists_via_proxy = "1" })
                }
            }
        })
        H.vfs_write("/etc/sing-box/config.json",
            '{"inbounds":[{"type":"tproxy","listen":"127.0.0.1","listen_port":1602},' ..
            '{"type":"mixed","listen":"127.0.0.1","listen_port":4534}]}')
        ENG.check(true)
        local r = ENG.apply("latest")
        assert.is_true(r.success)
        assert.equal("127.0.0.1:4534", r.detour)
        local used = false
        for _, cmd in ipairs(popen_cmds()) do
            if cmd:find("curl", 1, true) and cmd:find("pt-engine.apk", 1, true) then
                assert.truthy(cmd:find("-x 'http://127.0.0.1:4534'", 1, true),
                    "engine download goes through the local mixed inbound")
                used = true
            end
        end
        assert.is_true(used)
    end)

    it("direct download when podkop list routing is disabled", function()
        local ENG = begin_engine({
            latest = release_json("v1.14.4-r21", "slim", 100, DIGEST),
            tag_release = release_json("v1.14.4-r19", "slim", 90, DIGEST),
            after_singbox = SB_R21,
            uci = {
                podkop = {
                    H.sec("settings", "settings", { download_lists_via_proxy = "0" })
                }
            }
        })
        H.vfs_write("/etc/sing-box/config.json",
            '{"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":4534}]}')
        ENG.check(true)
        local r = ENG.apply("latest")
        assert.is_true(r.success)
        assert.equal("direct", r.detour)
        for _, cmd in ipairs(popen_cmds()) do
            if cmd:find("curl", 1, true) and cmd:find("pt-engine.apk", 1, true) then
                assert.is_nil(cmd:find("-x ", 1, true))
            end
        end
    end)

    it("switch to full: same-tag asset, one apk transaction removing the slim package", function()
        local ENG = begin_engine({
            singbox = SB_R20,
            apk_list = APK_SLIM,
            latest = release_json("v1.14.4-r21", "slim", 100, DIGEST),
            tag_release = release_json("v1.14.4-r20", "full", 140, DIGEST),
            after_singbox = SB_FULL,
            after_apk_list = APK_FULL,
            stage_size = 140,
            uci = { podkop = { H.sec("settings", "settings", { download_lists_via_proxy = "1" }) } }
        })
        H.vfs_write("/etc/sing-box/config.json",
            '{"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":4534}]}')
        ENG.check(true)
        local r = ENG.apply("switch")
        assert.is_true(r.success)
        assert.equal("switch", r.target)
        assert.equal("slim", r.flavor_before)
        assert.equal("full", r.flavor_after)
        assert.is_true(r.flavor_match)
        assert.equal("1.14.4-pdk-r20", r.version_after, "a switch preserves the installed version")
        assert.is_true(r.version_match)
        local apk_cmd
        for _, cmd in ipairs(popen_cmds()) do
            if cmd:find("apk add", 1, true) then apk_cmd = cmd end
        end
        assert.truthy(apk_cmd, "the switch installs through apk")
        assert.truthy(apk_cmd:find("'!podkop-engine'", 1, true),
            "the slim package leaves in the same apk transaction")
        assert.is_nil(apk_cmd:find("!podkop-engine-full", 1, true),
            "the package being installed is never the removal specifier")
    end)

    it("switch to slim removes the full package and verifies the flavor flip", function()
        local ENG = begin_engine({
            singbox = SB_FULL,
            apk_list = APK_FULL,
            latest = release_json("v1.14.4-r21", "full", 140, DIGEST),
            tag_release = release_json("v1.14.4-r20", "slim", 100, DIGEST),
            after_singbox = SB_R20,
            after_apk_list = APK_SLIM
        })
        ENG.check(true)
        local r = ENG.apply("switch")
        assert.is_true(r.success)
        assert.equal("full", r.flavor_before)
        assert.equal("slim", r.flavor_after)
        assert.is_true(r.flavor_match)
        local apk_cmd
        for _, cmd in ipairs(popen_cmds()) do
            if cmd:find("apk add", 1, true) then apk_cmd = cmd end
        end
        assert.truthy(apk_cmd and apk_cmd:find("'!podkop-engine-full'", 1, true))
    end)

    it("switch without an opposite-flavor asset is an explicit error", function()
        local ENG = begin_engine({
            latest = release_json("v1.14.4-r21", "slim", 100, DIGEST),
            tag_release = release_json("v1.14.4-r20", "slim", 100, DIGEST)
        })
        ENG.check(true)
        local r = ENG.apply("switch")
        assert.is_false(r.success)
        assert.equal("No opposite-flavor engine asset matches this device", r.error)
        assert.equal(0, count_substring("apk add"))
    end)

    it("switch ignores the cached decision and requires no update_available", function()
        local ENG = begin_engine({
            latest = release_json("v1.14.4-r20", "slim", 100, DIGEST),
            tag_release = release_json("v1.14.4-r20", "full", 140, DIGEST),
            after_singbox = SB_FULL,
            after_apk_list = APK_FULL,
            stage_size = 140
        })
        local info = ENG.check(true)
        assert.is_false(info.update_available)
        local r = ENG.apply("switch")
        assert.is_true(r.success, "a same-version switch is allowed even when up to date")
    end)

    it("rollback discovery routes the atom feed through the mixed detour when configured", function()
        local ENG = begin_engine({
            singbox = SB_R20,
            apk_list = APK_SLIM,
            latest = release_json("v1.14.4-r20", "slim", 100, DIGEST),
            tag_release = release_json("v1.14.4-r19", "slim", 90, DIGEST),
            uci = { podkop = { H.sec("settings", "settings", { download_lists_via_proxy = "1" }) } }
        })
        H.vfs_write("/etc/sing-box/config.json",
            '{"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":4534}]}')
        local info = ENG.check(true)
        assert.truthy(info.rollback, "rollback candidate must be discoverable")
        assert.equal("1.14.4-pdk-r19", info.rollback.version)
        local atom_via_proxy = false
        for _, cmd in ipairs(popen_cmds()) do
            if cmd:find("releases.atom", 1, true) then
                if cmd:find("-x 'http://127.0.0.1:4534'", 1, true) then atom_via_proxy = true end
            end
        end
        assert.is_true(atom_via_proxy,
            "the atom feed lives on github.com and must use the mixed detour when configured")
    end)

    it("rollback discovery stays direct when podkop list routing is disabled", function()
        local ENG = begin_engine({
            singbox = SB_R20,
            apk_list = APK_SLIM,
            latest = release_json("v1.14.4-r20", "slim", 100, DIGEST),
            tag_release = release_json("v1.14.4-r19", "slim", 90, DIGEST),
            uci = { podkop = { H.sec("settings", "settings", { download_lists_via_proxy = "0" }) } }
        })
        H.vfs_write("/etc/sing-box/config.json",
            '{"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":4534}]}')
        local info = ENG.check(true)
        assert.truthy(info.rollback)
        for _, cmd in ipairs(popen_cmds()) do
            if cmd:find("releases.atom", 1, true) then
                assert.is_nil(cmd:find("-x ", 1, true))
            end
        end
    end)
end)
