-- Generator adapter for the inspected Podkop 0.7.24-r1. Installation never generates a config.
local S = require("podkop-tweaker.services")
local L = require("podkop-tweaker.lib")
local M = {}
local generator = "/usr/bin/podkop"
local upstream = "5d245acb092884a40ed97699e7760b031be7399af8734fa63547b5f31c0d980d"
local integrated = "8163313da3ff459b2db31bb379df105de808ad1ceabb2a32b9bc2f6fb673e325"
local begin = "\nsing_box_save_config() {\n"
local tail = "\nsing_box_config_check() {"
local body = [[    # Podkop Tweaker synchronous outbound wrapper v1
    (
        umask 077
        config_get target settings config_path
        case "$target" in /*) ;; *) exit 1 ;; esac
        [ ! -L "$target" ] || exit 1
        lock=/var/lock/podkop-fragment.lock
        mkdir "$lock" || exit 1
        candidate=''
        cleanup() { [ -z "$candidate" ] || rm -f "$candidate"; rmdir "$lock"; }
        trap cleanup EXIT
        trap 'exit 1' HUP INT TERM
        snapshot() {
            [ ! -L "$target" ] || return 1
            if [ -f "$target" ]; then sha256sum < "$target"
            elif [ ! -e "$target" ]; then echo missing
            else return 1; fi
        }
        baseline=$(snapshot) || exit 1
        candidate=$(mktemp "${target}.pt-outbound.XXXXXX") || exit 1
        sing_box_cm_save_config_to_file "$config" "$candidate" || exit 1
        lua /usr/lib/lua/podkop-tweaker/outbound_wrapper.lua generate "$candidate" || exit 1
        sing_box_config_check "$candidate" || exit 1
        updated=$(sha256sum < "$candidate") || exit 1
        current=$(snapshot) || exit 1
        [ "$current" = "$baseline" ] || exit 1
        if [ "$current" != "$updated" ]; then
            mv -f "$candidate" "$target" || exit 1
            candidate=''
        fi
    ) || { log "Outbound wrapper: configuration not published; start aborted" "fatal"; exit 1; }
}
]]

local function recognized(src)
    local start = src:find(begin, 1, true)
    local finish = start and src:find(tail, start + #begin, true)
    if not finish or src:find(begin, start + 1, true) then return end
    return start + #begin, finish
end

local function legacy()
    local init = assert(S.read_file("/etc/init.d/podkop", 131072))
    if init:find("/usr/bin/podkop-fragment-patch.sh", 1, true) then return true end
    local ok, _, code = S.exec_checked("test ! -e /etc/init.d/podkop.orig && test ! -L /etc/rc.d/S99podkop-fragment && test ! -e /etc/rc.d/S99podkop-fragment")
    assert(code ~= nil, "Cannot inspect old wrapper")
    return not ok
end

function M.status()
    local src = assert(S.read_file(generator, 262144))
    local a, b = recognized(src)
    if not a or src:sub(a,b-1) ~= body then return false end
    local ok, hash = S.exec_checked("sha256sum /usr/bin/podkop")
    assert(ok, "Cannot identify installed generator")
    return hash:match("^%x+") == integrated and not legacy()
end

function M.install()
    local result, err = S.with_lock("podkop", function()
        local src = assert(S.read_file(generator, 262144))
        local a,b = recognized(src)
        assert(a, "Unsupported Podkop generator layout")
        local installed = src:sub(a,b-1) == body
        local identified, hash = S.exec_checked("sha256sum /usr/bin/podkop")
        assert(identified and hash:match("^%x+") == (installed and integrated or upstream),
            "Unsupported Podkop generator revision; no changes made")
        if legacy() then
            local ok, why = S.exec_checked("/etc/init.d/podkop-fragment disable")
            assert(ok, why)
            assert(not legacy(), "Old wrapper still active")
        end
        if not installed then
            local bytes = src:sub(1,a-1) .. body .. src:sub(b)
            local stage = assert(S.stage_file(generator, bytes, {executable=true}))
            local ok, why = S.exec_checked("sh -n " .. L.shell_escape(stage))
            if not ok or S.read_file(generator, 262144) ~= src then
                S.discard_stage(stage)
                error(why ~= "" and why or "Generator changed during installation")
            end
            assert(S.publish_file(stage, generator))
        end
        assert(M.status(), "Cannot confirm generator hook")
        return {success=true}
    end)
    return result or {error=err}
end
return M
