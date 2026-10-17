-- Native fd regression for APK 3.0.5's root-fd / hook-stdin boundary.
-- Installed Python 3 supplies POSIX fork/dup2/fchdir. No APK, packages, services,
-- configuration files or temporary files are changed.
package.path = "./usr/lib/lua/?.lua;" .. package.path
local SRV = require("podkop-tweaker.services")
local LIB = require("podkop-tweaker.lib")

-- Upstream order: context.c opens /, process.c connects hook stdin with dup2,
-- database.c calls fchdir(root_fd) before execve(script).
local probe = [[
import errno, os, sys
try:
    incoming = os.read(0, 1)
    print("stdin=eof" if incoming == b"" else "stdin=data", flush=True)
except OSError as error:
    if error.errno != errno.EBADF:
        raise
    print("stdin=closed", flush=True)
root_fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
print("root_fd=" + str(root_fd), flush=True)
reader, writer = os.pipe()
pid = os.fork()
if pid == 0:
    os.dup2(reader, 0)
    try:
        os.fchdir(root_fd)
    except OSError as error:
        print("fchdir=" + str(error.errno), flush=True)
        os._exit(127)
    print("fchdir=ok", flush=True)
    os._exit(0)
os.close(reader)
os.close(writer)
_, status = os.waitpid(pid, 0)
os.close(root_fd)
sys.exit(os.waitstatus_to_exitcode(status))
]]

local function capture(command)
    local fd = assert(io.popen(command, "r"))
    local output = assert(fd:read("*a"))
    assert(fd:close(), "cannot join native stdio probe")
    return output
end

local run = "python3 -c " .. LIB.shell_escape(probe)
local legacy = capture("exec 0<&-; (" .. run .. ") 2>&1; printf '\\nPT_EXIT:%s\\n' \"$?\"")
assert(legacy:find("stdin=closed\nroot_fd=0\nfchdir=20\n", 1, true), legacy)
assert(legacy:match("\nPT_EXIT:127\n$"), legacy)

local fixed = capture("exec 0<&-; " .. SRV.checked_command(run))
local root = tonumber(fixed:match("root_fd=(%d+)"))
assert(root and root >= 3, fixed)
assert(fixed:find("stdin=eof", 1, true) and fixed:find("fchdir=ok", 1, true), fixed)
assert(fixed:match("\nPT_EXIT:0\n$"), fixed)

local inherited = capture("printf incoming | sh -c " .. LIB.shell_escape(SRV.checked_command(run)))
assert(inherited:find("stdin=eof", 1, true) and inherited:find("fchdir=ok", 1, true), inherited)
assert(inherited:match("\nPT_EXIT:0\n$"), inherited)

local failed = capture("exec 0<&-; " .. SRV.checked_command("printf output; printf diagnostic >&2; exit 17"))
assert(failed == "outputdiagnostic\nPT_EXIT:17\n", failed)
print("Native APK stdio: PASS (closed-stdin ENOTDIR reproduced; occupied stdin protects root fd; stderr/nonzero status preserved; no APK/services changed)")
