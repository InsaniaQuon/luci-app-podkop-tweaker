#!/usr/bin/env python3
"""Native services.lua IO/ownership invariants; run only in the final test batch.

From the source checkout: python3 tests/native_io.py [--lua /path/to/lua5.1]

Installed Python 3, Lua 5.1, /bin/sh and native mktemp/chmod/mkdir/rmdir only.
No installs, environment/PATH edits, router access, APK or actual service calls.
The unmodified production Lua module runs in isolated, persistent OS actors.
The Lua helper guards/journals native IO and exposes post-open barriers; shell
IO primitives execute for real. Only sing-box validation and fixture service
commands are substituted. Their real subprocess exit status passes through the
production checked-command wrapper (including silent nonzero checker exits).
Checker exit 1 means invalid config; other nonzero exits mean IO failure. One
explicit checker-transport fault executes native ':' without the checked wrapper
to exercise missing PT_EXIT evidence, without fabricating shell output/markers.

Flow: A stage -> check -> B real stage open/pause -> A publish -> B write/publish
      lock owner -> nested same owner / foreign coroutine / second OS actor
      invalid source/backup -> retain usable recovery/live bytes

Local ROOT is repo/.. when env.md identifies that layout; CI ROOT is checkout.
Every invocation owns a timestamped MSK + unique ROOT/.test_tmp directory.
All children/reader threads are joined before successful-run cleanup. Failure
retains that run, its native operation logs and platform facts for inspection.

Platform boundary: WSL DrvFS/9p can hide a successfully renamed source until an
extra fixture source-reader closes. The isolated rename_visibility probe records
this boundary, using one production publication and checking exact bytes after
reader close. The main A/B invariant closes stage readers before publication,
as production does, and retains the already-published target reader across B.
Only expected-existing reader lookup ENOENT has a <=100ms visibility wait. Bytes
(including empty/partial), permissions on POSIX filesystems, publication failures
and native rename/open errors are never retried away. A missing ordinary target,
or absence after closing the diagnostic reader, remains a hard failure. Mounts
that cannot represent chmod modes mark permission assertions UNVERIFIED; byte,
ownership and lock assertions still run. This is no router acceptance claim.
"""

import argparse
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import traceback


REPO = Path(__file__).resolve().parents[1]
ROOT = REPO.parent if REPO.name == "repo" and (REPO.parent / "env.md").is_file() else REPO
TEMPORARY = ROOT / ".test_tmp"
VISIBILITY_SECONDS = 0.100
RPC_SECONDS = 20
GOOD = b'{"outbounds":[{"type":"direct","tag":"native-good"}]}\n'
NEXT = b'{"outbounds":[{"type":"direct","tag":"native-next"}]}\n'
OLD = b'{"outbounds":[{"type":"direct","tag":"native-old!"}]}\n'
UCI_GOOD = b"config native 'fixture'\n\toption value 'good'\n"
UCI_NEXT = b"config native 'fixture'\n\toption value 'next'\n"


def require(condition, message):
    # Keep invariants active even if the caller starts Python with -O.
    if not condition:
        raise AssertionError(message)


def local_path(root, value):
    path = Path(value)
    require(path.is_absolute(), "fixture path must be absolute: " + str(path))
    require(".." not in path.parts and path != root and root in path.parents,
            "path escaped native fixture: " + str(path))
    require(root in path.resolve().parents, "symlink escaped native fixture: " + str(path))
    return path


def append_event(root, actor, record):
    path = root / (actor + ".commands.jsonl")
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        data = (json.dumps(record, ensure_ascii=True) + "\n").encode()
        require(os.write(fd, data) == len(data), "cannot journal native command")
    finally:
        os.close(fd)


def guarded_shell(root, actor, command):
    """Safety boundary, not a mock of filesystem operations or PT_EXIT replies."""
    require("\x00" not in command and "`" not in command and "$(" not in command,
            "unsupported shell expansion in native fixture")
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()<>")
    lexer.whitespace_split = True
    lexer.commenters = ""
    tokens = list(lexer)
    require(tokens, "empty native command")
    primitives = {"umask", "mktemp", "chmod", "mkdir", "rmdir", "printf", "test", "[", ":", "exit", "true", "false"}
    separators = {";", "&&", "||", "("}
    head = True
    checker = False
    for token in tokens:
        require(token not in ("&", "|", ";;"), "no background/pipeline shell in native IO fixture")
        if token == ")":
            # A closed subshell may be followed by checked_command's stdin/stdout
            # redirects. Those are arguments to the group, not executable heads.
            head = False
            continue
        if token in separators:
            head = True
            continue
        if token.startswith("/") and token != "/dev/null":
            local_path(root, token)
        if head:
            if token == "sing-box":
                checker = True
            elif token.startswith(str(root / "services") + "/"):
                local_path(root, token)
            else:
                require(token in primitives, "unexpected native command head: " + repr(token))
            head = False
    if checker:
        pattern = r"(?<![\w./-])sing-box(?=\s+check\s+-c(?:\s|$))"
        replacement = shlex.join([sys.executable, str(Path(__file__).resolve()),
                                  "--fixture-command", str(root), actor, "checker"])
        replaced, count = re.subn(pattern, lambda match: replacement, command)
        require(count == 1 and tokens.count("sing-box") == 1,
                "only a single sing-box check -c is allowed")
        command = replaced
    append_event(root, actor, {"kind": "shell", "command": command})
    # No env argument and no PATH changes: the actual installed native utilities
    # allocate/open/chmod/mkdir/rmdir. PT_EXIT/PT_MKTEMP_EXIT come from this shell.
    return subprocess.run(["/bin/sh", "-c", command], cwd=root, timeout=15).returncode


def fixture_command(args):
    root = Path(args[0]).resolve()
    actor, kind, values = args[1], args[2], args[3:]
    require(root.is_dir() and TEMPORARY.resolve() in root.parents, "invalid native fixture root")
    require(re.fullmatch(r"[a-z0-9-]+", actor), "invalid native fixture actor")
    if kind == "shell":
        require(len(values) == 1, "shell bridge expects one original production command")
        return guarded_shell(root, actor, values[0])
    if kind == "checker":
        require(values[:2] == ["check", "-c"] and len(values) == 3, "unexpected checker arguments")
        path = local_path(root, values[2])
        content = path.read_bytes()
        value = None
        try:
            value = json.loads(content)
            valid = (isinstance(value, dict) and isinstance(value.get("outbounds"), list)
                     and all(isinstance(item, dict) for item in value["outbounds"])
                     and value.get("native_reject") is not True)
        except (ValueError, UnicodeError):
            valid = False
        # Match services.validate_service's fourth return: only checker exit 1
        # establishes invalid content; other exits are execution/IO uncertainty.
        code = 0 if valid else 1
        if isinstance(value, dict) and "native_checker_exit" in value:
            injected = value["native_checker_exit"]
            require(type(injected) is int and injected in (1, 2, 23, 127), "unsupported fixture checker exit")
            code = injected
        append_event(root, actor, {"kind": "checker", "path": str(path), "exit": code,
                                  "size": len(content), "sha256": hashlib.sha256(content).hexdigest()})
        # Deliberately silent on failure: empty stdout must not become success.
        return code
    if kind == "service":
        require(len(values) == 2 and values[0] in ("podkop", "stubby", "singbox")
                and values[1] in ("start", "stop", "restart", "reload"), "unexpected fixture service arguments")
        append_event(root, actor, {"kind": "service", "service": values[0], "action": values[1], "exit": 31})
        return 31
    raise AssertionError("unknown native bridge operation: " + kind)


def mount_facts(path):
    """Read-only diagnostics; no mount/system/env modifications."""
    target = str(path.resolve())
    best = None
    try:
        for line in Path("/proc/self/mountinfo").read_text().splitlines():
            left, right = line.split(" - ", 1)
            fields, filesystem = left.split(), right.split()
            mount = fields[4].replace("\\040", " ").replace("\\134", "\\")
            if target == mount or target.startswith(mount.rstrip("/") + "/"):
                if best is None or len(mount) > len(best["mount"]):
                    best = {"mount": mount, "type": filesystem[0], "source": filesystem[1], "line": line}
    except (OSError, ValueError, IndexError) as error:
        return {"error": repr(error)}
    return best or {"type": "unknown"}


class Run:
    def __init__(self, lua):
        require(os.name == "posix", "run with existing WSL/Linux Python 3")
        require(ROOT.is_dir() and (REPO / "usr/lib/lua/podkop-tweaker/services.lua").is_file(), "cannot identify project ROOT")
        executable = shutil.which(lua)
        require(executable, "installed Lua 5.1 is required; no software will be installed")
        self.lua = str(Path(executable).resolve())
        require(shutil.which("mktemp"), "installed BusyBox-compatible mktemp is required")
        require(Path("/bin/sh").is_file(), "native /bin/sh is required")
        require(not TEMPORARY.is_symlink(), "ROOT/.test_tmp must not redirect fixture writes outside ROOT")
        TEMPORARY.mkdir(exist_ok=True)
        stamp = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=3))).strftime("%d.%m.%Y_%H.%M")
        self.root = Path(tempfile.mkdtemp(prefix=stamp + "-native-io-", dir=TEMPORARY)).resolve()
        self.fixtures = []
        self.checks = []
        self.visibility = []
        self.modes = []
        self.actor_joins = []
        self.boundaries = []
        self.platform = {"uname": list(os.uname()), "python": sys.version, "lua": self.lua,
                         "mktemp": shutil.which("mktemp"), "mount": mount_facts(self.root)}
        self.posix_modes = None

    def mode_capability(self):
        path = self.root / "permission-capability"
        fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd)
        observed = []
        try:
            for mode in (0o600, 0o644, 0o755):
                path.chmod(mode)
                observed.append({"requested": oct(mode), "observed": oct(path.stat().st_mode & 0o777)})
        finally:
            path.unlink()
        self.platform["chmod_capability"] = observed
        supported = all(item["requested"] == item["observed"] for item in observed)
        if not supported:
            mount = self.platform["mount"]
            windows_mount = (mount.get("type", "").lower() in ("drvfs", "9p", "wslfs")
                             or "drvfs" in mount.get("line", "").lower())
            require(windows_mount, "native POSIX chmod roundtrip failed: " + repr(observed))
            self.boundaries.append("Mode-before-bytes/final-mode assertions UNVERIFIED: this DrvFS/9p mount cannot represent chmod modes; " + repr(observed))
        return supported

    def fixture(self, name):
        fixture = Fixture(self, name)
        self.fixtures.append(fixture)
        return fixture

    def read(self, path, context=None):
        """Retry only transient lookup ENOENT, never data or another IO error."""
        start, missing = time.monotonic(), 0
        while True:
            try:
                value = path.read_bytes()
                if missing:
                    self.visibility.append({"path": str(path), "misses": missing,
                                            "wait_ms": round((time.monotonic() - start) * 1000, 3), "context": context})
                return value
            except FileNotFoundError:
                missing += 1
                if time.monotonic() - start >= VISIBILITY_SECONDS:
                    self.visibility.append({"path": str(path), "misses": missing, "expired": True,
                                            "wait_ms": round((time.monotonic() - start) * 1000, 3), "context": context})
                    raise
                time.sleep(0.002)

    def mode(self, path, expected):
        actual = path.stat().st_mode & 0o777
        self.modes.append({"path": str(path), "expected": oct(expected), "observed": oct(actual),
                           "asserted": self.posix_modes})
        if self.posix_modes:
            require(actual == expected, "wrong native mode for " + str(path) + ": " + oct(actual))
        return oct(actual)

    def report(self, status, error=None, teardown=None):
        report = {"status": status, "root": str(self.root), "scenarios": self.checks, "error": error,
                  "platform": self.platform, "visibility_wait_seconds": VISIBILITY_SECONDS,
                  "visibility_events": self.visibility, "mode_observations": self.modes,
                  "actor_joins": self.actor_joins, "boundaries": self.boundaries, "teardown": teardown or []}
        (self.root / "report.json").write_text(json.dumps(report, indent=2) + "\n")


class Actor:
    def __init__(self, fixture, name):
        self.fixture, self.name = fixture, name
        self.busy, self.closed = False, False
        self.events = queue.Queue()
        self.error_file = (fixture.root / (name + ".stderr.log")).open("wb")
        try:
            self.process = subprocess.Popen(
                [fixture.run.lua, str(REPO / "tests/native_io_fixture.lua"), str(REPO), str(fixture.root), name, sys.executable],
                cwd=fixture.root, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.error_file,
                text=True, encoding="utf-8", bufsize=1, start_new_session=True)
        except BaseException:
            self.error_file.close()
            raise
        self.reader = threading.Thread(target=self.read_output, name="native-io-" + name)
        self.reader.start()

    def read_output(self):
        try:
            with (self.fixture.root / (self.name + ".stdout.jsonl")).open("w") as log:
                for line in self.process.stdout:
                    log.write(line)
                    log.flush()
                    try:
                        self.events.put(json.loads(line))
                    except ValueError:
                        self.events.put({"event": "error", "error": "non-protocol actor output: " + line})
        except BaseException as error:
            self.events.put({"event": "error", "error": repr(error)})
        finally:
            self.events.put(None)

    def ready(self):
        event = self.next_event()
        require(event.get("event") == "ready" and event.get("lua") == "Lua 5.1", "actor initialization failed: " + repr(event))
        require(event["lock_root"] == str(self.fixture.root / "locks"), "lock root was not relocated")
        return self

    def next_event(self):
        try:
            event = self.events.get(timeout=RPC_SECONDS)
        except queue.Empty:
            raise AssertionError("native actor timed out: " + self.name)
        require(event is not None, "native actor exited before replying: " + self.name + "; see " + str(self.fixture.root))
        require(event.get("event") != "error", "native actor " + self.name + ": " + str(event.get("error")))
        return event

    def send(self, request):
        with (self.fixture.root / (self.name + ".requests.jsonl")).open("a") as log:
            log.write(json.dumps(request, ensure_ascii=True) + "\n")
        self.process.stdin.write(json.dumps(request, ensure_ascii=True) + "\n")
        self.process.stdin.flush()

    def begin(self, op, **arguments):
        require(not self.busy, "actor already has an in-flight operation")
        self.busy = True
        self.send({"op": op, **arguments})
        return self.next_event()

    def finish(self, event):
        require(event.get("event") == "result", "expected result, got " + repr(event))
        self.busy = False
        return event["result"]

    def call(self, op, **arguments):
        return self.finish(self.begin(op, **arguments))

    def release(self):
        require(self.busy, "actor is not paused")
        self.send({"op": "release"})
        return self.finish(self.next_event())

    def close(self):
        if self.closed:
            return
        self.closed = True
        error = None
        try:
            if self.process.poll() is None and not self.busy:
                self.call("quit")
        except BaseException as caught:
            error = repr(caught)
        finally:
            with contextlib.suppress(BrokenPipeError, OSError):
                self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                error = error or "actor required SIGTERM during join"
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(self.process.pid, signal.SIGTERM)
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(self.process.pid, signal.SIGKILL)
                    self.process.wait(timeout=3)
            self.reader.join(timeout=5)
            if self.reader.is_alive():
                # A dead leader may still have a bridge/shell descendant holding
                # stdout. Signal only this actor's owned session/group, even if
                # the leader has already been reaped; do not leave a live reader.
                error = error or "actor descendants required termination during join"
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(self.process.pid, signal.SIGTERM)
                self.reader.join(timeout=3)
                if self.reader.is_alive():
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(self.process.pid, signal.SIGKILL)
                    self.reader.join(timeout=3)
            require(not self.reader.is_alive(), "actor stdout reader did not join")
            self.process.stdout.close()
            self.error_file.close()
            self.fixture.run.actor_joins.append({"fixture": self.fixture.root.name, "actor": self.name,
                                                "pid": self.process.pid, "returncode": self.process.returncode,
                                                "reader_joined": not self.reader.is_alive(), "error": error})
        require(error is None and self.process.returncode == 0,
                "native actor teardown failed: " + self.name + ": " + repr((error, self.process.returncode)))


class Fixture:
    def __init__(self, run, name):
        self.run = run
        self.root = run.root / name
        self.root.mkdir()
        for directory in ("live", "locks", "services"):
            (self.root / directory).mkdir()
        self.actors = []
        self.permanent = set()
        for basename in ("podkop.uci", "stubby.uci", "singbox.json"):
            self.permanent.add(self.root / "live" / basename)
            self.permanent.add(self.root / "live" / (basename + ".auto-backup"))
        for service in ("podkop", "stubby", "singbox"):
            script = self.root / "services" / service
            command = shlex.join([sys.executable, str(Path(__file__).resolve()), "--fixture-command",
                                  str(self.root), "service-stub", "service", service])
            script.write_text('#!/bin/sh\nexec ' + command + ' "$@"\n')
            script.chmod(0o755)

    def actor(self, name):
        actor = Actor(self, name)
        # Register before waiting for startup, so a missing integrated API cannot
        # leak an owned process or reader thread during the final batch.
        self.actors.append(actor)
        return actor.ready()

    def path(self, name="config.json"):
        path = self.root / "live" / name
        self.permanent.add(path)
        return path

    def lock_path(self, key):
        basename = "podkop-fragment.lock" if key == "singbox" else "podkop-tweaker-" + key + ".lock"
        return self.root / "locks" / basename

    def records(self, actor=None, suffix="commands"):
        paths = [self.root / (actor + "." + suffix + ".jsonl")] if actor else sorted(self.root.glob("*." + suffix + ".jsonl"))
        return [json.loads(line) for path in paths if path.exists() for line in path.read_text().splitlines()]

    def no_services(self):
        require(not [event for event in self.records() if event.get("kind") == "service"], "IO-only operation invoked a fixture service")

    def no_stages(self, allowed=()):
        # Discover unexpected live-directory entries, not guessed stage suffixes:
        # backup/validation callers are free to choose their own naming hints.
        allowed = self.permanent | set(allowed)
        leaked = [path for path in (self.root / "live").iterdir()
                  if path not in allowed]
        require(not leaked, "owned temporary leaked: " + repr(leaked))


class Observer:
    def __init__(self, run, path, allowed):
        self.run, self.path, self.allowed = run, path, set(allowed)
        self.stop, self.ready = threading.Event(), threading.Event()
        self.errors, self.reads = [], 0
        self.thread = threading.Thread(target=self.observe, name="native-io-file-reader")

    def observe(self):
        try:
            with self.path.open("rb", buffering=0) as original:
                while not self.stop.is_set():
                    original.seek(0)
                    require(original.read() in self.allowed, "open reader saw truncation/changed inode bytes")
                    require(self.run.read(self.path) in self.allowed, "new reader saw empty/partial/unpublished bytes")
                    self.reads += 1
                    self.ready.set()
                    self.stop.wait(0.002)
        except BaseException as error:
            self.errors.append(repr(error))
            self.ready.set()

    def __enter__(self):
        self.thread.start()
        try:
            require(self.ready.wait(RPC_SECONDS), "native observer did not start")
            require(not self.errors, "native observer failed at startup: " + repr(self.errors))
        except BaseException:
            self.stop.set()
            self.thread.join(timeout=5)
            require(not self.thread.is_alive(), "native observer did not join after startup failure")
            raise
        return self

    def __exit__(self, *unused):
        self.stop.set()
        self.thread.join(timeout=5)
        require(not self.thread.is_alive(), "native observer did not join")
        require(self.reads > 0 and not self.errors, "native read integrity failure: " + repr((self.reads, self.errors)))


def stage(actor, target, content, **options):
    result = actor.call("stage", target=str(target), content=content.decode(), options=options or None)
    require(result.get("path"), "stage_file failed: " + repr(result))
    path = local_path(actor.fixture.root, result["path"])
    stage_prefix(path, target, options.get("suffix", ".tmp-write"))
    require(actor.fixture.run.read(path) == content, "stage bytes differ from requested bytes")
    return path


def stage_prefix(path, target, suffix=".tmp-write"):
    # Assert the real allocation's current contract, never reconstruct a pathname
    # to open/publish/discard. All IO uses only the actual returned/opened path.
    prefix = str(target) + suffix + "."
    require(path.parent == target.parent and re.fullmatch(re.escape(prefix) + r"[A-Za-z0-9]{6}", str(path)),
            "stage does not match the actual adjacent native mktemp prefix: " + str(path))


def accepted(result):
    require(result.get("ok") is True, "native operation failed: " + repr(result))


def rejected(result):
    require(result.get("ok") is not True and isinstance(result.get("error"), str)
            and result["error"], "expected explicit native operation failure: " + repr(result))


def lock_acquired(result):
    require(result == {"entered": True, "first": "acquired", "second": False, "third": 37},
            "lock lost callback values: " + repr(result))


def lock_busy(result):
    require(result.get("entered") is False and result.get("first") is None
            and isinstance(result.get("second"), str) and result["second"],
            "competing actor was not explicitly busy: " + repr(result))


def rename_visibility(run):
    """Isolate native open-source rename behavior without retrying publication.

    A source-reader hold is extra fixture instrumentation, not a services.lua
    writer step: production closes both validation reads before rename. Keep its
    visibility result separate from the required publication/target-reader tests.
    """
    f = run.fixture("rename-handle-visibility")
    a = f.actor("a")
    results = []
    run.platform["rename_handle_visibility"] = results
    for hold in ("none", "source-reader", "target-reader"):
        target = f.path(hold + ".json")
        target.write_bytes(OLD)
        source = stage(a, target, GOOD)
        record = {"hold": hold, "source": str(source), "target": str(target)}
        results.append(record)
        reader = None
        try:
            if hold != "none":
                reader = (source if hold == "source-reader" else target).open("rb", buffering=0)
                record["fd_flags"] = fcntl.fcntl(reader.fileno(), fcntl.F_GETFL)
                record["descriptor_flags"] = fcntl.fcntl(reader.fileno(), fcntl.F_GETFD)
                stat = os.fstat(reader.fileno())
                record["reader"] = {"fd": reader.fileno(), "inode": stat.st_ino, "size": stat.st_size}
            before = len([event for event in f.records("a", "io") if event.get("operation") == "rename"])
            result = a.call("publish", path=str(source), target=str(target))
            record["publication"] = result
            accepted(result)  # Any native rename failure remains a hard failure.
            events = [event for event in f.records("a", "io") if event.get("operation") == "rename"]
            require(len(events) == before + 1 and events[-1]["ok"] is True, "publication was retried or native rename failed")
            try:
                content = run.read(target, context="rename-handle-" + hold)
                require(content == GOOD, "successful rename exposed incorrect/partial bytes")
                record["visible_while_held"] = True
            except FileNotFoundError:
                record["visible_while_held"] = False
            if reader is not None:
                reader.seek(0)
                held_bytes = reader.read()
                require(held_bytes == (GOOD if hold == "source-reader" else OLD), "native rename changed retained reader bytes")
                record["held_sha256"] = hashlib.sha256(held_bytes).hexdigest()
        finally:
            if reader is not None:
                reader.close()
                record["reader_closed"] = True
        published_bytes = run.read(target, context="rename-handle-after-close-" + hold)
        require(published_bytes == GOOD,
                "published target is missing/wrong after closing only the fixture reader")
        record["published_sha256"] = hashlib.sha256(published_bytes).hexdigest()
        record["visible_after_close"] = True
        if not record["visible_while_held"]:
            mount = run.platform["mount"]
            windows_mount = (mount.get("type", "").lower() == "drvfs"
                             or "drvfs" in mount.get("line", "").lower())
            require(hold == "source-reader" and windows_mount,
                    "native target visibility failure outside the isolated DrvFS source-reader boundary: " + repr(record))
            run.boundaries.append("DrvFS open-source-reader visibility boundary OBSERVED on this mount: "
                                  "one successful native rename; exact published bytes visible after reader close; "
                                  "no rename replay or extended lookup wait. See rename_handle_visibility.")
        require(not source.exists(), "successful native rename left its source name")
    f.no_stages()
    f.no_services()


def checked_stage_interleaving(run):
    f = run.fixture("checked-a-then-b-open")
    a, b = f.actor("a"), f.actor("b")
    target = f.path()
    target.write_bytes(OLD)
    predictable = Path(str(target) + ".tmp-native")
    predictable.write_bytes(b"foreign fixed-name sentinel")
    first = stage(a, target, GOOD, suffix=".tmp-native")
    accepted(a.call("check-stage", path=str(first)))
    checked = [event for event in f.records("a") if event.get("kind") == "checker"]
    require(len(checked) == 1 and checked[0]["sha256"] == hashlib.sha256(GOOD).hexdigest(), "A was not checked from its real stage")
    opened = b.begin("stage", target=str(target), content=NEXT.decode(),
                     options={"suffix": ".tmp-native"}, pause_open=True)
    require(opened.get("event") == "stage-open", "B did not pause after native open")
    second = local_path(f.root, opened["path"])
    stage_prefix(second, target, ".tmp-native")
    require(second.parent == target.parent and second not in (first, target, predictable), "B reopened A/live/fixed-name stage")
    require(run.read(second) == b"", "B barrier is not before stage bytes")
    run.mode(second, 0o600)
    require(run.read(first) == GOOD, "B's native open truncated checked A")
    require(run.read(target) == OLD, "stage open changed the live file")
    # Production closes its stage-check descriptors before rename. An additional
    # fixture-held source reader alters DrvFS lookup behavior, isolated above.
    accepted(a.call("publish", path=str(first), target=str(target)))
    require(run.read(target) == GOOD, "A did not publish its checked bytes")
    # Retain A's published target inode through B's write and publication. This
    # still proves that B cannot truncate published A without holding a source fd.
    with target.open("rb", buffering=0) as reader:
        require(reader.read() == GOOD, "published A reader does not match checked bytes")
        result = b.release()
        require(result.get("path") == str(second), "B returned a different allocation than its open stage")
        require(run.read(second) == NEXT and run.read(target) == GOOD, "B's later write truncated published A")
        reader.seek(0)
        require(reader.read() == GOOD, "A's published inode was modified through B's stage")
        accepted(b.call("publish", path=str(second), target=str(target)))
        require(run.read(target) == NEXT, "B did not publish its own checked expected bytes")
        reader.seek(0)
        require(reader.read() == GOOD, "later publication mutated A's retained inode")
    require(run.read(predictable) == b"foreign fixed-name sentinel", "predictable foreign name was touched")
    f.no_stages(allowed=(predictable,))
    f.no_services()


def owned_publication(run):
    f = run.fixture("foreign-and-consumed-ownership")
    a, b = f.actor("a"), f.actor("b")
    target, other = f.path(), f.path("other.json")
    target.write_bytes(OLD)
    other.write_bytes(NEXT)
    own = stage(a, target, GOOD)
    rejected(b.call("publish", path=str(own), target=str(target)))
    b.call("discard", path=str(own))
    require(run.read(own) == GOOD and run.read(target) == OLD, "foreign publication/cleanup touched A's stage")
    require(not [event for event in f.records("b", "io") if event.get("operation") == "remove" and event.get("path") == str(own)],
            "foreign actor attempted unlink, even though the bytes survived")
    accepted(a.call("publish", path=str(own), target=str(target)))
    # A consumed registration must not authorize deleting a later foreign file at
    # the same pathname. This also checks that publication unregisters ownership.
    own.write_bytes(b"foreign reuse of consumed pathname")
    a.call("discard", path=str(own))
    require(run.read(own) == b"foreign reuse of consumed pathname", "consumed stage retained unlink authority")
    rejected(a.call("publish", path=str(own), target=str(target)))
    require(run.read(target) == GOOD and run.read(own) == b"foreign reuse of consumed pathname", "replayed publication touched foreign/live bytes")
    arbitrary = f.path("foreign.tmp-native")
    arbitrary.write_bytes(NEXT)
    rejected(a.call("publish", path=str(arbitrary), target=str(other)))
    a.call("discard", path=str(arbitrary))
    require(run.read(other) == NEXT and run.read(arbitrary) == NEXT, "unregistered path acquired publication/cleanup authority")
    wrong = stage(a, target, NEXT)
    rejected(a.call("publish", path=str(wrong), target=str(other)))
    require(run.read(target) == GOOD and run.read(other) == NEXT, "stage published to an unregistered target")
    a.call("discard", path=str(wrong))
    f.no_stages(allowed=(own, arbitrary))
    f.no_services()


def tampered_publication(run):
    for name, tampered in (("empty", b""), ("same-length", GOOD.replace(b"native-good", b"native-evil"))):
        f = run.fixture("tampered-" + name)
        a = f.actor("a")
        target = f.path()
        target.write_bytes(OLD)
        own = stage(a, target, GOOD)
        accepted(a.call("check-stage", path=str(own)))
        own.write_bytes(tampered)  # Actual independent writer after the check.
        rejected(a.call("publish", path=str(own), target=str(target)))
        require(run.read(target) == OLD, "tampered stage replaced live bytes: " + name)
        a.call("discard", path=str(own))
        f.no_stages()
        f.no_services()


def atomic_and_modes(run):
    f = run.fixture("atomic-reader-and-private-staging")
    a = f.actor("a")
    target = f.path("state.bin")
    values = (b"A\x00" * 8192, b"B\x00" * 8192, b"C\x00" * 8192)
    target.write_bytes(values[0])
    with Observer(run, target, values):
        for number in range(8):
            accepted(a.call("atomic", target=str(target), content=values[1 + number % 2].decode(), options=None))
    require(run.read(target) == values[2], "atomic writer returned without publishing exact bytes")
    for label, options, final_mode in (("private", {"mode": "600"}, 0o600),
                                        ("default", None, 0o644),
                                        ("executable", {"executable": True}, 0o755)):
        path = f.path(label)
        path.write_bytes(b"old")
        opened = a.begin("atomic", target=str(path), content="private-before-write", options=options, pause_open=True)
        require(opened.get("event") == "stage-open", "atomic writer bypassed native stage open")
        temporary = local_path(f.root, opened["path"])
        stage_prefix(temporary, path)
        require(temporary != path and temporary.parent == path.parent, "atomic write used live/nonadjacent open")
        require(run.read(temporary) == b"" and run.read(path) == b"old", "bytes landed before private-stage observation")
        run.mode(temporary, 0o600)
        accepted(a.release())
        require(run.read(path) == b"private-before-write", "wrong published mode-test bytes")
        run.mode(path, final_mode)
    f.no_stages()
    f.no_services()


def native_locks(run):
    for key in ("podkop", "singbox"):
        f = run.fixture("two-os-actors-" + key)
        a, b = f.actor("a"), f.actor("b")
        held = a.begin("hold-lock", key=key, nested=True)
        require(held.get("event") == "lock-held", "owner did not hold native lock")
        path = f.lock_path(key)
        require(path.is_dir(), "expected interoperable mkdir lock path absent: " + str(path))
        lock_busy(b.call("lock", key=key))
        require(path.is_dir(), "loser removed the winner's lock")
        lock_acquired(a.release())
        require(not path.exists(), "owner failed to release native lock")
        lock_acquired(b.call("lock", key=key))
        require(not path.exists(), "next owner leaked lock")
        f.no_services()
    f = run.fixture("external-shell-compatible-lock")
    a = f.actor("a")
    path = f.lock_path("singbox")
    path.mkdir()  # Independent Python OS actor, same mkdir protocol as Fragment.
    marker = path / "foreign-owner"
    marker.write_bytes(b"do not steal or unlink")
    lock_busy(a.call("lock", key="singbox"))
    require(path.is_dir() and run.read(marker) == b"do not steal or unlink", "external lock was stolen/cleaned")
    marker.unlink()
    path.rmdir()  # Explicit fixture-owner release, never updater lock stealing.
    lock_acquired(a.call("lock", key="singbox"))
    f.no_services()


def coroutine_and_exception(run):
    f = run.fixture("coroutine-ownership")
    a = f.actor("a")
    require(a.call("coroutines", key="subscriptions") == {"main_and_coroutine": True}, "coroutine ownership assertions did not complete")
    require(not f.lock_path("subscriptions").exists(), "coroutine owner leaked native lock")
    f.no_services()

    f = run.fixture("exception-owned-cleanup")
    a, b = f.actor("a"), f.actor("b")
    target, pending_target = f.path(), f.path("pending.json")
    target.write_bytes(OLD)
    pending_target.write_bytes(NEXT)
    foreign = stage(b, target, NEXT)
    result = a.call("exception", key="singbox", target=str(target), pending_target=str(pending_target), content=GOOD.decode())
    require(result.get("caught") is True, "callback exception was not rethrown")
    for path in result["paths"].values():
        require(not Path(path).exists(), "exception leaked own registered stage: " + path)
    require(run.read(target) == GOOD and run.read(pending_target) == NEXT, "exception cleanup removed published/live bytes")
    require(run.read(foreign) == NEXT, "exception cleanup unlinked another OS actor's stage")
    require(not [event for event in f.records("a", "io") if event.get("operation") == "remove" and event.get("path") == str(foreign)],
            "exception attempted a foreign unlink")
    require(not f.lock_path("singbox").exists(), "exception leaked resource lock")
    lock_acquired(b.call("lock", key="singbox"))
    b.call("discard", path=str(foreign))
    f.no_stages()
    f.no_services()


def backup_restore(run):
    for service, basename, good, replacement, invalid in (
            ("podkop", "podkop.uci", UCI_GOOD, UCI_NEXT, b"config native 'unterminated\n"),
            ("stubby", "stubby.uci", UCI_GOOD, UCI_NEXT, b"config native 'unterminated\n"),
            ("singbox", "singbox.json", GOOD, NEXT, b'{"outbounds":[],"native_reject":true}\n')):
        f = run.fixture("backup-restore-" + service)
        a = f.actor("a")
        live = f.path(basename)
        backup = Path(str(live) + ".auto-backup")
        for unusable in (b"", b" \n\t", invalid):
            live.write_bytes(good)
            backup.write_bytes(unusable)
            rejected(a.call("restore", service=service))
            require(run.read(live) == good and run.read(backup) == unusable,
                    "invalid/empty restore changed live or its evidence: " + service)
            live.write_bytes(unusable)
            backup.write_bytes(good)
            skipped = a.call("backup", service=service)
            accepted(skipped)
            require(isinstance(skipped.get("metadata"), dict) and skipped["metadata"].get("warning"),
                    "invalid source was not explicitly skipped with a backup warning: " + repr(skipped))
            require(run.read(live) == unusable and run.read(backup) == good,
                    "invalid/empty current source poisoned usable backup: " + service)
            applied = a.call("apply", service=service, content=replacement.decode())
            require(applied.get("success") is True and applied.get("warning"),
                    "valid apply failed or lost the skipped-backup warning: " + repr(applied))
            require(run.read(live) == replacement and run.read(backup) == good,
                    "apply replaced the usable backup with invalid prior bytes: " + service)
        live.write_bytes(replacement)
        backup.write_bytes(good)
        accepted(a.call("backup", service=service))
        require(run.read(live) == replacement and run.read(backup) == replacement,
                "valid native backup did not publish the source bytes: " + service)
        backup.write_bytes(good)
        accepted(a.call("restore", service=service))
        require(run.read(live) == good and run.read(backup) == good, "valid checked restore failed: " + service)
        f.no_stages()
        f.no_services()


def checked_exit(run):
    f = run.fixture("quiet-native-command-exit")
    a = f.actor("a")
    result = a.call("exec", command="exit 23")
    require(result.get("ok") is False and result.get("code") == 23 and not result.get("details", "").strip(),
            "quiet native nonzero was inferred from stdout: " + repr(result))
    result = a.call("exec", command=":")
    require(result.get("ok") is True and result.get("code") == 0, "quiet successful native command failed: " + repr(result))
    diagnostic = "diagnostic-begin:" + "x" * 12288 + ":diagnostic-end"
    result = a.call("exec", command="printf '%s' stdout-begin; printf '%s' " + shlex.quote(diagnostic) + " >&2; exit 17")
    require(result.get("ok") is False and result.get("code") == 17
            and result.get("details", "").startswith("stdout-begin") and diagnostic in result.get("details", ""),
            "native stderr/full diagnostic/nonzero result was lost")
    live, backup = f.path("singbox.json"), f.path("singbox.json.auto-backup")
    live.write_bytes(GOOD)
    backup.write_bytes(OLD)
    accepted(a.call("validate", service="singbox", content=GOOD.decode()))
    cases = (("not json", 1, "invalid"),
             ('{"outbounds":[],"native_reject":true}\n', 1, "invalid"),
             ('{"outbounds":[],"native_checker_exit":2}\n', 2, "io"),
             ('{"outbounds":[],"native_checker_exit":23}\n', 23, "io"),
             ('{"outbounds":[],"native_checker_exit":127}\n', 127, "io"))
    for content, code, kind in cases:
        before = len([event for event in f.records("a") if event.get("kind") == "checker"])
        result = a.call("validate", service="singbox", content=content)
        rejected(result)
        require(result.get("kind") == kind, "checker exit was misclassified: " + repr((code, result)))
        checks = [event for event in f.records("a") if event.get("kind") == "checker"]
        require(len(checks) == before + 1 and checks[-1]["exit"] == code
                and checks[-1]["sha256"] == hashlib.sha256(content.encode()).hexdigest(),
                "validation did not observe the selected real quiet checker exit")
        require(run.read(live) == GOOD and run.read(backup) == OLD, "validation changed live/backup")
    result = a.call("validate", service="singbox", content=" \n\t")
    rejected(result)
    require(result.get("kind") == "invalid", "basic whitespace validation lost invalid kind")
    result = a.call("validate", service="singbox", content=GOOD.decode(), checker_transport="missing-marker")
    rejected(result)
    require(result.get("kind") == "io" and "Command outcome is unknown" in result.get("details", "")
            and "final PT_EXIT marker" in result.get("details", ""),
            "missing PT_EXIT evidence was not classified as IO failure: " + repr(result))
    faults = [event for event in f.records("a", "io") if event.get("operation") == "checker-transport-missing-marker"]
    require(len(faults) == 1, "missing-marker transport fault was not exercised")
    require(run.read(live) == GOOD and run.read(backup) == OLD, "marker loss changed live/backup")
    # A checker execution/IO failure cannot authorize skipping backup validation
    # and publishing over that uncertain current source as if it were invalid.
    uncertain = b'{"outbounds":[],"native_checker_exit":23}\n'
    live.write_bytes(uncertain)
    rejected(a.call("backup", service="singbox"))
    result = a.call("apply", service="singbox", content=NEXT.decode())
    require(result.get("success") is False and result.get("error") and not result.get("applied"),
            "IO-failed backup validation was treated as a safe invalid-source skip: " + repr(result))
    require(run.read(live) == uncertain and run.read(backup) == OLD, "checker IO failure changed live/recovery bytes")
    # An explicit fake service script fails quietly too; never touch init.d/APK.
    result = a.call("exec", command=shlex.quote(str(f.root / "services/singbox")) + " restart")
    require(result.get("ok") is False and result.get("code") == 31, "quiet fixture service exit was lost")
    events = [event for event in f.records() if event.get("kind") == "service"]
    require(len(events) == 1 and events[0]["exit"] == 31, "unexpected fixture service calls")
    f.no_stages()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lua", default="lua5.1", help="existing Lua 5.1 executable (no installation)")
    parser.add_argument("--scenario", choices=("all", "rename-visibility", "checked-stage"), default="all",
                        help="scoped final-phase native diagnosis; default runs all invariants")
    parser.add_argument("--keep", action="store_true", help="retain this joined successful run as handoff evidence")
    arguments = parser.parse_args()
    run = Run(arguments.lua)
    failure, teardown = None, []
    scenarios = (rename_visibility, checked_stage_interleaving, owned_publication, tampered_publication, atomic_and_modes,
                 native_locks, coroutine_and_exception, backup_restore, checked_exit)
    if arguments.scenario != "all":
        scenarios = (rename_visibility,) if arguments.scenario == "rename-visibility" else (checked_stage_interleaving,)
    try:
        run.posix_modes = run.mode_capability()
        run.report("running")
        for scenario in scenarios:
            scenario(run)
            run.checks.append(scenario.__name__)
    except BaseException:
        failure = traceback.format_exc()
    finally:
        # Try every registered resource even if one join fails. No removal occurs
        # while an owned process/reader is active or cleanup is unresolved.
        for fixture in run.fixtures:
            for actor in fixture.actors:
                try:
                    actor.close()
                except BaseException:
                    teardown.append(traceback.format_exc())
    if failure or teardown:
        run.report("failed", error=failure, teardown=teardown)
        print("Native IO invariant regression FAILED; owned run retained: " + str(run.root), file=sys.stderr)
        print(failure or "\n".join(teardown), file=sys.stderr)
        print("Review report.json and *.io/commands/requests/stdout/stderr logs; native rename errors are not retried.", file=sys.stderr)
        return 1
    run.report("passed")
    for boundary in run.boundaries:
        print("Platform boundary: " + boundary)
    print("Native IO invariants: PASS (" + str(len(scenarios)) + " selected scenario groups; actual production Lua/native IO/mktemp/process locks; controlled checker/services)")
    print("Visibility: " + str(len(run.visibility)) + " finite ENOENT waits; <=100ms each, no byte/rename retries")
    if arguments.keep:
        print("Evidence: " + str(run.root))
        print("Cleanup: joined " + str(len(run.actor_joins)) + " owned OS actors and their reader threads; retained only this run as requested")
        return 0
    try:
        shutil.rmtree(run.root)
    except OSError:
        print("Cleanup FAILED after resource joins; remaining owned data retained: " + str(run.root), file=sys.stderr)
        raise
    print("Cleanup: joined all owned OS actors/reader threads, removed only this unique .test_tmp run; no router/PATH/system changes")
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--fixture-command":
        sys.exit(fixture_command(sys.argv[2:]))
    sys.exit(main())
