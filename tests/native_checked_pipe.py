#!/usr/bin/env python3
"""Real Lua 5.1 checked-pipe/SIGCHLD regression; no router or temporary files.

Run from the checkout: python3 -B tests/native_checked_pipe.py
Requires Linux /proc, installed liblua5.1.so.0, Python 3 and /bin/sh. CI's
existing liblua5.1-dev dependency supplies the runtime library; absence is a
hard error, never a skipped test or permission to provision software.

One-thread ctypes worker -> production checked_command -> native io.popen/read
    inherited writer + actual child exit -> no-SA_RESTART SIGCHLD -> errno 4
    production detached hook -> EOF/final PT_EXIT while that hook is still alive
    production exec_checked + native EINTR -> explicit failure, no replay

Only WRAPPER_HOOK_BODY/WRAPPER_HOOK assignment expressions are evaluated from
the production generator, with PATCH_SCRIPT naming a harmless shell function.
No init/installation functions or live router paths are invoked. An internal
sleep function validates the production delay argument and waits on an IPC
barrier instead of a clock. The historical inherited hook is a negative control.

For raw reads, an outer shell closes its capture descriptors after the actual
checked_command marker, then waits on an exit barrier. This separates EOF from
SIGCHLD deterministically: the inherited writer still prevents EOF, while the
detached hook permits EOF before shell exit. The exec_checked cases also use
unaltered production commands/readers and the natural foreground-shell exit,
checking success, exit 17 and a genuine inherited-writer IO failure end to end.

Kernel blocked-read observations and IPC, not elapsed time, establish ordering.
Deadlines are failure watchdogs; scenarios/commands are never replayed. A private
session and process-local subreaper join every orphan even on assertion failure;
the SIGCHLD handler never steals a child belonging to Lua pclose. This models the
libubox no-SA_RESTART signal boundary, not actual router UCI/services or LuCI.
"""

import ctypes
import errno
import fcntl
import json
import os
from pathlib import Path
import re
import selectors
import signal
import socket
import subprocess
import sys
import time
import traceback


REPO = Path(__file__).resolve().parents[1]
LIBRARY = "liblua5.1.so.0"
WATCHDOG_SECONDS = 20
OUTPUT = "foreground stdout\nforeground stderr\n"
LEGACY_HOOK = "( sleep 5 && pt_probe_patch ) &"
LUA_GLOBALSINDEX = -10002


def require(condition, message):
    # Invariants must remain active under python -O, too.
    if not condition:
        raise AssertionError(message)


def shared_lua():
    try:
        return ctypes.CDLL(LIBRARY)
    except OSError as error:
        raise RuntimeError(
            "Native checked pipe requires installed liblua5.1.so.0; the existing "
            "CI liblua5.1-dev package depends on this shared runtime. "
            "No dependency is installed or silently skipped by this probe."
        ) from error


class Lua:
    """Small installed-Lua bridge; io and pipe userdata are never substituted."""

    def __init__(self):
        self.lib = shared_lua()
        declarations = {
            "luaL_newstate": ([], ctypes.c_void_p),
            "luaL_openlibs": ([ctypes.c_void_p], None),
            "lua_close": ([ctypes.c_void_p], None),
            "luaL_loadbuffer": ([ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t,
                                 ctypes.c_char_p], ctypes.c_int),
            "lua_pcall": ([ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int], ctypes.c_int),
            "lua_getfield": ([ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p], None),
            "lua_setfield": ([ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p], None),
            "lua_settop": ([ctypes.c_void_p, ctypes.c_int], None),
            "lua_pushlstring": ([ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t], None),
            "lua_type": ([ctypes.c_void_p, ctypes.c_int], ctypes.c_int),
            "lua_toboolean": ([ctypes.c_void_p, ctypes.c_int], ctypes.c_int),
            "lua_tonumber": ([ctypes.c_void_p, ctypes.c_int], ctypes.c_double),
            "lua_tolstring": ([ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_size_t)],
                              ctypes.c_void_p),
        }
        for name, (arguments, result) in declarations.items():
            function = getattr(self.lib, name)
            function.argtypes, function.restype = arguments, result
        self.state = self.lib.luaL_newstate()
        require(self.state, "cannot allocate installed Lua 5.1 state")
        self.lib.luaL_openlibs(self.state)

    def value(self, index=-1):
        kind = self.lib.lua_type(self.state, index)
        if kind == 0:
            return None
        if kind == 1:
            return bool(self.lib.lua_toboolean(self.state, index))
        if kind == 3:
            value = self.lib.lua_tonumber(self.state, index)
            return int(value) if value.is_integer() else value
        require(kind == 4, "unexpected Lua result type: " + str(kind))
        size = ctypes.c_size_t()
        pointer = self.lib.lua_tolstring(self.state, index, ctypes.byref(size))
        return ctypes.string_at(pointer, size.value).decode("utf-8")

    def get(self, name):
        self.lib.lua_getfield(self.state, LUA_GLOBALSINDEX, name.encode())
        try:
            return self.value()
        finally:
            self.lib.lua_settop(self.state, -2)

    def put(self, name, value):
        data = value.encode("utf-8")
        self.lib.lua_pushlstring(self.state, data, len(data))
        self.lib.lua_setfield(self.state, LUA_GLOBALSINDEX, name.encode())

    def run(self, source):
        data = source.encode("utf-8")
        status = self.lib.luaL_loadbuffer(self.state, data, len(data), b"native_checked_pipe")
        if status == 0:
            status = self.lib.lua_pcall(self.state, 0, 0, 0)
        if status:
            message = self.value()
            self.lib.lua_settop(self.state, 0)
            raise RuntimeError("native Lua failure: " + str(message))

    def close(self):
        if self.state:
            self.lib.lua_close(self.state)
            self.state = None


def production_hooks():
    source = (REPO / "etc/init.d/podkop-fragment").read_text()
    assignments = re.findall(r"^[ \t]*(WRAPPER_HOOK(?:_BODY)?)=(.+)$", source, re.MULTILINE)
    require(len(assignments) == 2 and {name for name, _ in assignments} ==
            {"WRAPPER_HOOK_BODY", "WRAPPER_HOOK"}, "expected unique production hook assignments")
    safe = []
    for name, expression in assignments:
        # Evaluate assignments only, never source the init script. The permitted
        # RHS is a double-quoted value or a quoted, builtin-printf substitution.
        # Neither permits another command substitution or a live patcher call.
        expression = expression.strip()
        if expression.startswith('"$(') and expression.endswith(')"'):
            inner = expression[3:-2]
            require(re.fullmatch(r'''printf(?:[ \t]+(?:'[^'\n]*'|"[^"\n`]*"))+''', inner),
                    "unsupported production printf assignment: " + name)
            quoted = re.findall(r'"([^"\n]*)"', inner)
        else:
            require(re.fullmatch(r'"[^"\n`]*"', expression),
                    "unsupported production hook assignment: " + name)
            quoted = [expression[1:-1]]
        for value in quoted:
            remainder = value.replace("$PATCH_SCRIPT", "").replace("$WRAPPER_HOOK_BODY", "")
            require("$" not in remainder and "`" not in remainder and "\\" not in remainder,
                    "unexpected expansion in production hook assignment: " + name)
        safe.append(name + "=" + expression)
    evaluated = subprocess.run(
        ["/bin/sh", "-c", "pt_probe_patch() { :; }\nPATCH_SCRIPT=pt_probe_patch\n" + "\n".join(safe) +
         '\nprintf "%s\\000%s\\000" "$WRAPPER_HOOK_BODY" "$WRAPPER_HOOK"'],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=5)
    fields = evaluated.stdout.decode().split("\0")
    require(len(fields) == 3 and fields[2] == "", "invalid production hook evaluation")
    body, line = fields[:2]
    require(line == "\t" + body, "generated hook line and recognized body differ")
    require(body.count("pt_probe_patch") == 1 and "/usr/" not in body and "/etc/" not in body,
            "production hook did not resolve to the harmless patch function")
    return body, line


def send(channel, message):
    data = json.dumps(message, ensure_ascii=True).encode()
    require(len(data) < 16384, "oversized private IPC message")
    require(channel.send(data) == len(data), "incomplete private IPC packet")


def receive(channel):
    data = channel.recv(16384)
    require(data, "private IPC channel closed")
    return json.loads(data)


def shell_body(hook, events, foreground, background, exit_code):
    # The hook owns/reaps its barrier subshell just as it would a native sleep.
    # Keeping read's temporary stdin redirection in that child lets /proc inspect
    # the hook's original three stdio FDs. It cannot signal the capture worker.
    return "\n".join([
        "sleep() {",
        '  [ "$#" -eq 1 ] && [ "$1" = 5 ] || exit 91',
        "  printf 'hook_wait\\n' >&" + str(events),
        "  ( IFS= read -r pt_hook_gate <&" + str(background) + " || exit 92; " +
        '[ "$pt_hook_gate" = release-hook ] || exit 93 ) || exit 94',
        "  printf 'hook_released\\n' >&" + str(events),
        "}",
        "pt_probe_patch() { printf 'hook_patch\\n' >&" + str(events) + "; }",
        "printf 'execute\\n' >&" + str(events),
        "printf 'foreground stdout\\n'",
        "printf 'foreground stderr\\n' >&2",
        hook,
        'pt_hook_pid=$!',
        "printf 'hook_pid:%s\\n' \"$pt_hook_pid\" >&" + str(events),
        "printf 'foreground_wait\\n' >&" + str(events),
        "IFS= read -r pt_foreground_gate <&" + str(foreground) + " || exit 94",
        '[ "$pt_foreground_gate" = release-foreground ] || exit 95',
        "printf 'foreground_exit\\n' >&" + str(events),
        "exit " + str(exit_code),
    ])


def children(pid):
    return [int(value) for value in
            Path("/proc", str(pid), "task", str(pid), "children").read_text().split()]


def worker(channel, descriptors, hook, with_handler, use_exec, exit_code):
    lua = None
    try:
        os.setsid()
        # POSIX sh need only support single-digit redirection operands. Keep
        # barrier FDs below 10, without clobbering either the IPC socket or a
        # still-needed source FD when the launcher inherited other descriptors.
        saved = [fcntl.fcntl(fd, fcntl.F_DUPFD_CLOEXEC, 32) for fd in descriptors]
        channel_fd = fcntl.fcntl(channel.fileno(), fcntl.F_DUPFD_CLOEXEC, 32)
        channel.close()
        channel = socket.socket(fileno=channel_fd)
        for descriptor in descriptors:
            os.close(descriptor)
        for source, target in zip(saved, (6, 7, 8, 9)):
            os.dup2(source, target, inheritable=True)
            os.close(source)
        events, foreground, background, shell_exit = (6, 7, 8, 9)
        require(len(list(Path("/proc/self/task").iterdir())) == 1, "capture worker must have one thread")
        lua = Lua()
        lua.put("_probe_path", str(REPO / "usr/lib/lua/?.lua"))
        lua.run("""
assert(_VERSION == "Lua 5.1", "installed Lua must be 5.1")
package.path = _probe_path .. ";" .. package.path
_probe_services = require("podkop-tweaker.services")
""")
        lua.put("_probe_body", shell_body(hook, events, foreground, background, exit_code))
        if not use_exec:
            lua.put("_probe_tail", "\nexec >/dev/null 2>&1\n" +
                    "printf 'capture_closed\\n' >&" + str(events) + "\n" +
                    "IFS= read -r pt_exit_gate <&" + str(shell_exit) + " || exit 96\n" +
                    '[ "$pt_exit_gate" = release-exit ] || exit 97\nexit 0')
            lua.run("_probe_command = _probe_services.checked_command(_probe_body) .. _probe_tail")
        observed_signals = []

        def sigchld(signum, frame):
            # Do not waitpid here: the actual popen child still belongs to pclose.
            observed_signals.append(signum)

        signal.signal(signal.SIGCHLD, sigchld if with_handler else signal.SIG_DFL)
        if with_handler:
            signal.siginterrupt(signal.SIGCHLD, True)
        send(channel, {"event": "ready", "handler": with_handler, "threads": 1})
        require(receive(channel) == {"action": "run"}, "invalid worker start barrier")
        if use_exec:
            lua.run("""
_probe_ok, _probe_details, _probe_code, _probe_metadata = _probe_services.exec_checked(_probe_body)
if type(_probe_metadata) == "table" then
    _probe_unknown = _probe_metadata.unknown
    if type(_probe_metadata.errors) == "table" then
        _probe_error_count = #_probe_metadata.errors
        local first = _probe_metadata.errors[1]
        if type(first) == "table" then
            _probe_failure_stage, _probe_failure_errno = first.stage, first.errno
        end
    end
end
""")
            result = {"ok": lua.get("_probe_ok"), "details": lua.get("_probe_details"),
                      "code": lua.get("_probe_code"), "unknown": lua.get("_probe_unknown"),
                      "error_count": lua.get("_probe_error_count"),
                      "stage": lua.get("_probe_failure_stage"), "errno": lua.get("_probe_failure_errno")}
        else:
            lua.run("""
_probe_pipe = assert(io.popen(_probe_command, "r"))
_probe_raw, _probe_error, _probe_errno = _probe_pipe:read("*a")
""")
            result = {"raw": lua.get("_probe_raw"), "error": lua.get("_probe_error"),
                      "errno": lua.get("_probe_errno")}
            send(channel, {"event": "read", **result})
            lua.run("""
_probe_closed, _probe_close_error = _probe_pipe:close()
_probe_pipe = nil
""")
            result.update(closed=lua.get("_probe_closed"), close_error=lua.get("_probe_close_error"))
        require(not children(os.getpid()), "pclose left an unreaped capture child")
        send(channel, {"event": "result", "signals": observed_signals, **result})
        require(receive(channel) == {"action": "finish"}, "invalid worker finish barrier")
        lua.close()
        lua = None
        channel.close()
        os._exit(0)
    except BaseException:
        try:
            send(channel, {"event": "worker_error", "error": traceback.format_exc()})
        finally:
            # lua_close can itself call pclose after an unexpected exception.
            # The supervisor's private-group watchdog owns that failure teardown.
            if lua is not None:
                lua.close()
            os._exit(1)


def state(pid):
    try:
        return Path("/proc", str(pid), "stat").read_text().rsplit(")", 1)[1].split()[0]
    except FileNotFoundError:
        return None


class Scenario:
    def __init__(self, name, hook, with_handler=True, use_exec=False, exit_code=0):
        self.name, self.with_handler, self.use_exec = name, with_handler, use_exec
        self.deadline = time.monotonic() + WATCHDOG_SECONDS
        self.events, self.messages, self.joined = [], {}, []
        self.buffer, self.eof = b"", set()
        self.worker, self.hook_pid, self.shell_pid = None, None, None
        self.foreground_released = self.background_released = False
        self.exit_released = False
        self.parent, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        event_read, event_write = os.pipe()
        foreground_read, self.foreground_write = os.pipe()
        background_read, self.background_write = os.pipe()
        exit_read, self.exit_write = os.pipe()
        self.event_read = event_read
        self.selector = selectors.DefaultSelector()
        child_descriptors = (event_write, foreground_read, background_read, exit_read)
        try:
            self.worker = os.fork()
            if self.worker == 0:
                self.parent.close()
                self.selector.close()
                for descriptor in (event_read, self.foreground_write, self.background_write, self.exit_write):
                    os.close(descriptor)
                worker(child, child_descriptors, hook, with_handler, use_exec, exit_code)
                os._exit(1)
        finally:
            child.close()
            for descriptor in child_descriptors:
                os.close(descriptor)
        os.set_blocking(event_read, False)
        self.selector.register(self.parent, selectors.EVENT_READ, "worker")
        self.selector.register(event_read, selectors.EVENT_READ, "shell")

    def pump(self, timeout=0):
        for key, _ in self.selector.select(timeout):
            if key.data == "worker":
                data = self.parent.recv(16384)
                if not data:
                    self.eof.add("worker")
                    self.selector.unregister(self.parent)
                    continue
                message = json.loads(data)
                kind = message.get("event")
                require(kind not in self.messages, self.name + ": duplicate worker result: " + str(kind))
                self.messages[kind] = message
                if kind == "worker_error":
                    raise AssertionError(self.name + ": " + message["error"])
            else:
                data = os.read(self.event_read, 8192)
                if not data:
                    self.eof.add("shell")
                    self.selector.unregister(self.event_read)
                    continue
                self.buffer += data
                require(len(self.buffer) < 8192, self.name + ": oversized shell IPC record")
                while b"\n" in self.buffer:
                    record, self.buffer = self.buffer.split(b"\n", 1)
                    self.events.append(record.decode("ascii"))
                    require(len(self.events) < 32, self.name + ": command replay or excessive shell events")

    def wait(self, predicate, context):
        while True:
            self.pump()
            if predicate():
                return
            require(time.monotonic() < self.deadline,
                    self.name + ": watchdog waiting for " + context + "; events=" + repr(self.events) +
                    "; messages=" + repr(self.messages))
            require("worker" not in self.eof, self.name + ": worker exited before " + context)
            self.pump(0.005)

    def wait_events(self, *events):
        self.wait(lambda: all(event in self.events for event in events), ", ".join(events))

    def blocked_read(self):
        # Gates keep the shell/hook stable during these kernel observations.
        # Compare the actual syscall FD with popen stdout, rather than accepting
        # a socket/IPC read or a merely sleeping Python worker as capture evidence.
        fields = Path("/proc", str(self.worker), "syscall").read_text().split()
        if not fields or fields[0] == "running" or len(fields) < 3:
            return False
        wait_channel = Path("/proc", str(self.worker), "wchan").read_text().strip()
        if "pipe_read" not in wait_channel:
            return False
        descriptor = int(fields[1], 0)
        pipe = os.readlink(Path("/proc", str(self.worker), "fd", str(descriptor)))
        if pipe != self.capture_pipe:
            return False
        require(len(list(Path("/proc", str(self.worker), "task").iterdir())) == 1,
                self.name + ": signal delivery worker gained another thread")
        return True

    def alive_hook(self):
        require(state(self.hook_pid) not in (None, "Z", "X"), self.name + ": hook finished before release")
        require(not self.background_released, self.name + ": hook release preceded capture proof")
        require("hook_patch" not in self.events, self.name + ": patch function ran before the deferred barrier")

    def release(self, kind):
        descriptor = getattr(self, kind + "_write")
        attribute = kind + "_released"
        require(not getattr(self, attribute), self.name + ": barrier released twice: " + kind)
        value = {"foreground": b"release-foreground\n", "background": b"release-hook\n",
                 "exit": b"release-exit\n"}[kind]
        require(os.write(descriptor, value) == len(value), self.name + ": incomplete barrier release")
        setattr(self, attribute, True)

    def start(self, detached):
        self.wait(lambda: "ready" in self.messages, "one-thread installed-Lua worker")
        send(self.parent, {"action": "run"})
        self.wait(lambda: ("foreground_wait" in self.events and "hook_wait" in self.events and
                           any(item.startswith("hook_pid:") for item in self.events)), "shell/hook IPC barriers")
        pids = children(self.worker)
        require(len(pids) == 1, self.name + ": capture worker must own exactly one popen child: " + repr(pids))
        self.shell_pid = pids[0]
        self.capture_pipe = os.readlink(Path("/proc", str(self.shell_pid), "fd/1"))
        require(self.capture_pipe.startswith("pipe:["), self.name + ": popen stdout is not a real pipe")
        self.hook_pid = int(next(item.split(":")[1] for item in self.events if item.startswith("hook_pid:")))
        require(os.getpgid(self.hook_pid) == self.worker, self.name + ": hook escaped private process group")
        self.alive_hook()
        descriptors = [os.readlink(Path("/proc", str(self.hook_pid), "fd", str(fd))) for fd in (0, 1, 2)]
        expected = ["/dev/null"] * 3 if detached else ["/dev/null", self.capture_pipe, self.capture_pipe]
        require(descriptors == expected, self.name + ": wrong production hook descriptors: " + repr(descriptors))
        self.wait(self.blocked_read, "actual Lua capture read blocked on its popen pipe")

    def finish(self):
        self.wait_events("hook_released", "hook_patch")
        require(self.events.count("hook_wait") == self.events.count("hook_patch") == 1,
                self.name + ": delayed hook did not run exactly once")
        require(self.events.count("execute") == 1, self.name + ": mutation/command was replayed")
        require(self.events.count("foreground_exit") == 1, self.name + ": foreground exit count differs")
        send(self.parent, {"action": "finish"})

    def join(self, failed):
        """Reap only our group; no waitpid on a child still belonging to pclose."""
        if self.worker is None:
            return
        if failed:
            try:
                os.killpg(self.worker, signal.SIGKILL)
            except ProcessLookupError:
                # A failure before setsid still leaves just our forked worker.
                try:
                    os.kill(self.worker, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        deadline = time.monotonic() + 10
        while True:
            # Once workers exit, the subreaper adopts every orphaned hook. The
            # shell itself owns/reaps its foreground subshell; Lua owns pclose.
            while True:
                try:
                    pid, status = os.waitpid(-self.worker, os.WNOHANG)
                except ChildProcessError:
                    break
                if not pid:
                    break
                self.joined.append((pid, os.waitstatus_to_exitcode(status)))
            try:
                os.killpg(self.worker, 0)
            except ProcessLookupError:
                # Also cover a worker that failed before creating its group.
                if not any(pid == self.worker for pid, _ in self.joined):
                    pid, status = os.waitpid(self.worker, os.WNOHANG)
                    if pid:
                        self.joined.append((pid, os.waitstatus_to_exitcode(status)))
                    else:
                        require(time.monotonic() < deadline, self.name + ": pre-session worker did not exit")
                        time.sleep(0.005)
                        continue
                break
            if time.monotonic() >= deadline:
                if not failed:
                    self.join(True)
                raise AssertionError(self.name + ": private process group failed to join")
            time.sleep(0.005)
        require(not children(os.getpid()), self.name + ": unjoined private descendants remain")
        if not failed:
            require(all(code == 0 for _, code in self.joined), self.name + ": private actor failed: " + repr(self.joined))
            require(any(pid == self.worker for pid, _ in self.joined), self.name + ": worker not joined")

    def close(self):
        self.selector.close()
        self.parent.close()
        for descriptor in (self.event_read, self.foreground_write, self.background_write, self.exit_write):
            os.close(descriptor)


def run_raw(name, hook, with_handler, detached, exit_code=0):
    scenario = Scenario(name, hook, with_handler=with_handler, exit_code=exit_code)
    passed = False
    try:
        scenario.start(detached)
        scenario.release("foreground")
        scenario.wait_events("foreground_exit", "capture_closed")
        if detached:
            scenario.wait(lambda: "read" in scenario.messages, "EOF with the production hook still alive")
            read = scenario.messages["read"]
            require(read == {"event": "read", "raw": OUTPUT + "\nPT_EXIT:" + str(exit_code) + "\n",
                             "error": None, "errno": None}, name + ": incomplete stdout/stderr/exit capture: " + repr(read))
            scenario.alive_hook()
            require(state(scenario.shell_pid) not in (None, "Z", "X"), name + ": shell exit escaped its barrier")
            scenario.release("exit")
        else:
            scenario.wait(scenario.blocked_read, "inherited writer still preventing EOF")
            require("read" not in scenario.messages, name + ": inherited control got EOF before writer release")
            scenario.release("exit")
            if not with_handler:
                scenario.wait(lambda: state(scenario.shell_pid) == "Z", "real child exit without a SIGCHLD handler")
                scenario.wait(scenario.blocked_read, "control still blocked after actual foreground child exit")
                require("read" not in scenario.messages, name + ": control read completed before writer release")
                scenario.alive_hook()
                scenario.release("background")
        scenario.wait(lambda: "result" in scenario.messages, "native read and pclose result")
        result = scenario.messages["result"]
        require(result["closed"] is True and result["close_error"] is None, name + ": pclose did not join: " + repr(result))
        if with_handler:
            require(result["signals"] == [signal.SIGCHLD], name + ": actual child exit did not deliver SIGCHLD: " + repr(result))
        else:
            require(result["signals"] == [], name + ": handler-free control received a fabricated signal")
        if with_handler and not detached:
            require(result["raw"] is None and result["errno"] == errno.EINTR and
                    result["error"] == os.strerror(errno.EINTR), name + ": expected genuine Lua errno 4: " + repr(result))
        else:
            require(result["raw"] == OUTPUT + "\nPT_EXIT:" + str(exit_code) + "\n" and
                    result["error"] is None and result["errno"] is None, name + ": full final marker lost: " + repr(result))
        if not scenario.background_released:
            scenario.alive_hook()
            scenario.release("background")
        scenario.finish()
        passed = True
    finally:
        try:
            scenario.join(not passed)
        finally:
            scenario.close()
    return len(scenario.joined)


def run_exec(hook, detached, exit_code=0):
    name = ("production exec_checked detached exit " + str(exit_code) if detached else
            "production exec_checked native EINTR/no replay")
    scenario = Scenario(name, hook, use_exec=True, exit_code=exit_code)
    passed = False
    try:
        scenario.start(detached)
        scenario.release("foreground")
        scenario.wait(lambda: "result" in scenario.messages, "natural production exec_checked result")
        result = scenario.messages["result"]
        require(result["signals"] == [signal.SIGCHLD], name + ": no actual child-exit SIGCHLD: " + repr(result))
        if detached:
            require(result["ok"] is (exit_code == 0) and result["code"] == exit_code and
                    result["details"] == OUTPUT and result["unknown"] is None and result["errno"] is None,
                    name + ": stdout/stderr or known exit outcome lost: " + repr(result))
        else:
            require(result["ok"] is False and result["code"] is None and
                    isinstance(result["details"], str) and os.strerror(errno.EINTR) in result["details"],
                    name + ": native IO failure was swallowed or became command success: " + repr(result))
            require(result["unknown"] is True and result["error_count"] == 1 and
                    result["stage"] == "read" and result["errno"] == errno.EINTR,
                    name + ": genuine read errno/unknown evidence was lost: " + repr(result))
        scenario.alive_hook()
        scenario.release("background")
        scenario.finish()
        passed = True
    finally:
        try:
            scenario.join(not passed)
        finally:
            scenario.close()
    return len(scenario.joined)


def run_failure_teardown(hook):
    scenario = Scenario("failed-capture private descendant teardown", hook)
    try:
        scenario.start(detached=True)
        # Exercise the assertion/watchdog cleanup path at a positively observed
        # blocked read, with the foreground, hook and barrier child still alive.
        # No IO fault, timeout, kill of an unrelated actor or successful retry.
    finally:
        try:
            scenario.join(True)
        finally:
            scenario.close()
    require(any(code == -signal.SIGKILL for _, code in scenario.joined),
            "failed-capture teardown did not terminate its private actors")
    require(state(scenario.hook_pid) is None and state(scenario.shell_pid) is None,
            "failed-capture teardown left a private descendant behind")
    return len(scenario.joined)


def main():
    require(sys.platform == "linux", "run with installed Linux/WSL Python 3 and Lua 5.1")
    require(Path("/proc/self/syscall").is_file(), "Linux /proc syscall/fd inspection is required")
    require(not children(os.getpid()), "probe supervisor must start without existing child actors")
    require(signal.getsignal(signal.SIGCHLD) == signal.SIG_DFL, "probe supervisor needs ordinary child ownership")
    shared_lua()  # Explicit dependency failure before any actors start.
    body, line = production_hooks()
    libc = ctypes.CDLL(None, use_errno=True)
    libc.prctl.restype = ctypes.c_int
    previous = ctypes.c_int()
    require(libc.prctl(37, ctypes.byref(previous), 0, 0, 0) == 0, "cannot inspect process-local child subreaper")
    require(libc.prctl(36, 1, 0, 0, 0) == 0, "cannot enable private descendant joining")
    actors = 0
    try:
        actors += run_raw("inherited before-handler control", LEGACY_HOOK, False, False)
        actors += run_raw("inherited no-SA_RESTART negative control", LEGACY_HOOK, True, False)
        actors += run_raw("production WRAPPER_HOOK_BODY detached EOF", body, True, True)
        actors += run_raw("production WRAPPER_HOOK detached exit 17", line, True, True, exit_code=17)
        actors += run_exec(LEGACY_HOOK, detached=False)
        actors += run_exec(body, detached=True)
        actors += run_exec(line, detached=True, exit_code=17)
        actors += run_failure_teardown(body)
    finally:
        require(not children(os.getpid()), "private descendants remain after probe teardown")
        require(libc.prctl(36, previous.value, 0, 0, 0) == 0, "cannot restore process-local subreaper state")
    print("Native checked pipe: PASS (8 deterministic native Lua/SIGCHLD/teardown cases; real errno 4; "
          "production hook EOF before background completion; full stdout/stderr/exit 17; "
          "exec_checked fails without replay; " + str(actors) + " worker/orphan actors joined; no files created)")


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        print("Native checked pipe: FAIL", file=sys.stderr)
        traceback.print_exc()
        sys.exit(1)
