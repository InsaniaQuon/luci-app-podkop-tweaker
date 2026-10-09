-- Native POSIX-shell regression. Run from repo with Lua 5.1, not through the VFS.
-- Writes only unique files under tests/, then removes them. No services are called.
package.path = "./usr/lib/lua/?.lua;" .. package.path
local SRV = require("podkop-tweaker.services")
local LIB = require("podkop-tweaker.lib")
math.randomseed(os.time())
local prefix = "tests/.pt-background-" .. os.time() .. "-" .. math.random(100000, 999999)
local ready, done = prefix .. "-ready", prefix .. "-done"
local command = "printf ready > " .. LIB.shell_escape(ready) .. "; sleep 1; printf done > " .. LIB.shell_escape(done)
-- Simulate the router's missing optional utility without changing PATH or software.
local parent = "nohup() { return 127; }; " .. SRV.background_command(command) .. "printf '%s' \"$!\""
local pipe = assert(io.popen(parent))
local pid = pipe:read("*a")
assert(pipe:close())
assert(pid:match("^%d+$"), "background shell PID missing")
local function wait_for(path)
    for _ = 1, 60 do
        local fd = io.open(path, "rb")
        if fd then local value = fd:read("*a"); fd:close(); if value ~= "" then return value end end
        os.execute("sleep 0.05")
    end
end
local ok, err = pcall(function()
    assert(wait_for(ready) == "ready", "background command did not start after its parent exited")
    assert(LIB.exit_ok(os.execute("kill -HUP " .. pid)), "cannot signal owned test process")
    assert(wait_for(done) == "done", "background command did not survive HUP")
end)
os.remove(ready)
os.remove(done)
assert(ok, err)
local marker_pipe = assert(io.popen(SRV.background_command(":", 1) .. "printf '\\nPT_EXIT:%s\\n' \"$?\""))
local marker = marker_pipe:read("*a")
assert(marker_pipe:close())
assert(marker == "\nPT_EXIT:0\n", "unexpected launch-status reply: " .. string.format("%q", marker))
local status, kind, code = os.execute(SRV.background_command(":", 1))
assert(LIB.exit_ok(status, kind, code), "direct background exit status was not successful")
print("Native background command: PASS (missing nohup, parent exit, redirected stdio and HUP survival; no services changed)")
