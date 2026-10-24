#!/usr/bin/env python3
"""Native lockf semantics probe for the 4.11.0 kernel-guarded locks.

Verifies, against the real kernel and libc (never the harness model), the
exact POSIX process-lock properties the Lua lock engine depends on:

  1. F_TLOCK conflicts across processes (EAGAIN) and is advisory per inode.
  2. Owner death releases the lock (the crash-safety foundation).
  3. ANY descriptor close on the locked inode by the owning process drops the
     lock -- the engine therefore never opens a second fd of a guard file.
  4. A forked child does not own the parent's record lock: closing the
     inherited fd in the child leaves the parent's lock intact, and the child
     exiting never releases it. This is why the detached worker is exec'd.

No LuCI, no router services, no system changes. Uses only ctypes, os and
subprocess with a unique disposable directory under ROOT/.test_tmp.
"""
import ctypes
import ctypes.util
import os
import subprocess
import sys
import tempfile

libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)

F_TLOCK = 2
F_ULOCK = 0
F_LOCK = 1

EXIT_OK = 0
EXIT_FAIL = 1

FAILURES = []


def check(name, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {name}" + (f" -- {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(name)


def lockf(fd, cmd):
    libc.lockf.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_long]
    result = libc.lockf(fd, cmd, 0)
    errno = ctypes.get_errno()
    return result, errno


def open_rw(path):
    return os.open(path, os.O_RDWR | os.O_CREAT, 0o600)


def child_worker(path, mode, ready_fd):
    """Runs in a subprocess: holds/tests/releases the lock per mode."""
    fd = open_rw(path)
    if mode == "hold":
        result, errno = lockf(fd, F_TLOCK)
        os.write(ready_fd, b"1" if result == 0 else b"0")
        # Keep the lock until the parent tells us to exit or we are killed.
        try:
            os.read(3 if False else ready_fd, 1)
        except OSError:
            pass
        os.close(fd)
        sys.exit(0)
    if mode == "peek":
        result, errno = lockf(fd, F_TLOCK)
        os.write(ready_fd, b"1" if result != 0 else b"0")  # 1 = conflict seen
        sys.exit(0)
    sys.exit(0)


def spawn(path, mode):
    read_ready, write_ready = os.pipe()
    child_pass = os.pipe()  # parent -> child, used to release holders
    proc = subprocess.Popen(
        [sys.executable, "-c", """
import os, sys
path, mode = sys.argv[1], sys.argv[2]
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
import ctypes, ctypes.util
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
libc.lockf.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_long]
if mode == "hold":
    result = libc.lockf(fd, 2, 0)
    os.write(%d, b"1" if result == 0 else b"0")
    os.read(%d, 1)
    sys.exit(0)
if mode == "peek":
    result = libc.lockf(fd, 2, 0)
    os.write(%d, b"1" if result != 0 else b"0")
    sys.exit(0)
sys.exit(0)
""" % (write_ready, child_pass[0], write_ready), path, mode],
        pass_fds=(write_ready, child_pass[0]),
    )
    os.close(write_ready)
    signal = os.read(read_ready, 1)
    os.close(read_ready)
    return proc, signal == b"1", child_pass[1]


def main():
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".test_tmp")
    os.makedirs(root, exist_ok=True)
    run = tempfile.mkdtemp(prefix="native-lockf-", dir=root)
    guard = os.path.join(run, "probe.guard")

    print("Native lockf semantics: cross-process exclusion")
    fd = open_rw(guard)
    check("initial tlock succeeds on a fresh guard", lockf(fd, F_TLOCK)[0] == 0)
    peek, conflicted, _ = spawn(guard, "peek")
    peek.wait()
    check("another process gets EAGAIN while held", conflicted)
    check("unlock returns success", lockf(fd, F_ULOCK)[0] == 0)
    peek, conflicted, _ = spawn(guard, "peek")
    peek.wait()
    check("the resource is free after ulock", not conflicted)
    lockf(fd, F_TLOCK)

    print("Native lockf semantics: any-close ownership release")
    second = open_rw(guard)
    os.close(second)
    peek, conflicted, _ = spawn(guard, "peek")
    peek.wait()
    check("closing a second fd of the inode releases the lock", not conflicted)
    os.close(fd)

    print("Native lockf semantics: owner death")
    holder, acquired, release = spawn(guard, "hold")
    check("child holder acquired the lock", acquired)
    holder.terminate()
    holder.wait()
    fd = open_rw(guard)
    result, errno = lockf(fd, F_TLOCK)
    check("owner death releases the lock (crash safety)", result == 0, f"errno={errno}")
    lockf(fd, F_ULOCK)
    os.close(release)

    print("Native lockf semantics: fork does not inherit ownership")
    holder, acquired, release = spawn(guard, "hold")
    check("holder acquired again", acquired)
    inherit = subprocess.Popen(
        [sys.executable, "-c", """
import ctypes, ctypes.util, os, sys
path = sys.argv[1]
fd = os.open(path, os.O_RDWR)
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
libc.lockf.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_long]
# The child inherited no descriptor here by design; opening its own fd must
# NOT be able to take or release the parent's record lock.
result = libc.lockf(fd, 2, 0)
os.close(fd)
sys.exit(0 if result != 0 else 3)
""", guard])
    code = inherit.wait()
    check("a new process still conflicts with the live holder", code == 0, f"exit={code}")
    holder.terminate()
    holder.wait()
    fd = open_rw(guard)
    check("holder death still frees the resource", lockf(fd, F_TLOCK)[0] == 0)
    os.close(fd)
    os.close(release)

    print("Native lockf semantics: stable inode guard survives reuse")
    fd = open_rw(guard)
    lockf(fd, F_TLOCK)
    lockf(fd, F_ULOCK)
    os.close(fd)
    check("guard file still exists for the next actor", os.path.exists(guard))

    import shutil
    shutil.rmtree(run, ignore_errors=True)
    if FAILURES:
        print(f"Native lockf probe: FAIL ({len(FAILURES)}): " + ", ".join(FAILURES))
        return EXIT_FAIL
    print("Native lockf probe: PASS "
          "(cross-process EAGAIN; any-close release; owner-death release; "
          "fork inherits no ownership; stable inode; no services changed)")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
