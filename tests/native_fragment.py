#!/usr/bin/env python3
"""Native POSIX-shell Fragment lifecycle regression; run from repo:

    python3 tests/native_fragment.py

Uses installed Python 3 and /bin/sh, without jq, package installs, PATH changes,
router access or real services. Production shell copies differ only in fixed
runtime paths/command locations. Shell command stubs inject IO/process failures;
the JSON stub strictly accepts the production filters and parses real JSON.
This tests filesystem/process contracts, not the router's jq, procd or hooks.
All synthetic files are in a unique ROOT/.test_tmp run; subprocesses are joined
before successful fixtures are removed. Failed runs are retained for inspection.
ROOT is the outer project for the local repo/ layout, or the checkout in CI.
"""

import contextlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time


VALID_FILTER = 'length == 1 and (.[0] | type == "object")'
INSPECT_FILTERS = {
    '[.outbounds[] | select(.tls.enabled == true and .tls.fragment == true and .tls.record_fragment == true)] | length > 0': "both",
    '[.outbounds[] | select(.tls.enabled == true and .tls.fragment == true)] | length > 0': "fragment",
    '[.outbounds[] | select(.tls.enabled == true and .tls.record_fragment == true and .tls.fragment != true)] | length > 0': "record",
}
PATCH_FILTERS = {
    '(.outbounds[] | select(.tls.enabled == true) | .tls) |= . + {"fragment": ($f == "true"), "record_fragment": ($rf == "true"), "fragment_fallback_delay": $fd}',
    '(.outbounds[] | select(.tls.enabled == true) | .tls) |= . + {"fragment": ($f == "true"), "record_fragment": ($rf == "true")} | (.outbounds[] | select(.tls.enabled == true) | .tls) |= del(.fragment_fallback_delay)',
}
ORIGINAL = {
    "outbounds": [
        {"tag": "proxy", "tls": {"enabled": True, "server_name": "example.invalid", "fragment_fallback_delay": "old"}},
        {"tag": "untouched", "tls": {"enabled": False, "custom": [1, 2]}},
        {"tag": "direct", "type": "direct"},
    ],
    "custom": {"preserve": "yes"},
}
EXTERNAL = {"outbounds": [{"tag": "external", "type": "direct"}], "custom": "new writer"}


def encoded(value):
    return (json.dumps(value, indent=2) + "\n").encode()


def external_write(state):
    path = Path(state["config"])
    temporary = path.with_name(path.name + ".fixture-external")
    temporary.write_bytes(encoded(EXTERNAL))
    os.replace(temporary, path)


def event(state, kind, args):
    fd = os.open(str(Path(state["root"]) / "events.jsonl"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, (json.dumps([kind, *args]) + "\n").encode())
    finally:
        os.close(fd)


def pause(state, label):
    root = Path(state["root"])
    (root / (label + ".ready")).touch()
    deadline = time.monotonic() + 15
    while not (root / (label + ".release")).exists():
        if time.monotonic() > deadline:
            raise RuntimeError("fixture barrier timed out: " + label)
        time.sleep(0.01)


def fixture_command(state_path, kind, args):
    state = json.loads(Path(state_path).read_text())
    root = Path(state["root"])
    assert root.parent.parent.name == ".test_tmp", root
    failure = state.get("failure", "")
    event(state, kind, args)
    if kind == "jq":
        options = list(args)
        variables = {}
        while options and options[0].startswith("-"):
            flag = options.pop(0)
            if flag == "--arg":
                name, value = options[:2]
                del options[:2]
                variables[name] = value
            else:
                assert flag in ("-e", "-s"), flag
        query, path = options
        assert Path(path).parent == Path(state["config"]).parent, path
        try:
            data = json.loads(Path(path).read_text())
        except (ValueError, OSError):
            return 4
        if query == VALID_FILTER:
            return 0 if isinstance(data, dict) else 1
        if query in INSPECT_FILTERS:
            if failure == "inspect":
                return 5
            if not isinstance(data.get("outbounds"), list):
                return 5
            mode = INSPECT_FILTERS[query]
            matches = []
            for outbound in data["outbounds"]:
                tls = outbound.get("tls", {})
                matches.append(tls.get("enabled") is True and (
                    (mode == "both" and tls.get("fragment") is True and tls.get("record_fragment") is True)
                    or (mode == "fragment" and tls.get("fragment") is True)
                    or (mode == "record" and tls.get("record_fragment") is True and tls.get("fragment") is not True)))
            return 0 if any(matches) else 1
        assert query in PATCH_FILTERS, query
        if failure == "jq_partial":
            sys.stdout.write('{"outbounds":[')
            return 5
        if failure == "jq_empty":
            return 0
        if failure == "jq_invalid":
            sys.stdout.write("not json")
            return 0
        for outbound in data["outbounds"]:
            tls = outbound.get("tls", {})
            if tls.get("enabled") is True:
                tls["fragment"] = variables["f"] == "true"
                tls["record_fragment"] = variables["rf"] == "true"
                if "fd" in variables:
                    tls["fragment_fallback_delay"] = variables["fd"]
                else:
                    tls.pop("fragment_fallback_delay", None)
        output = encoded(data).decode()
        if state.get("pause_patch"):
            midpoint = len(output) // 2
            sys.stdout.write(output[:midpoint])
            sys.stdout.flush()
            pause(state, "patch")
            output = output[midpoint:]
        sys.stdout.write(output)
        return 0
    if kind == "check":
        assert args[:2] == ["check", "-c"], args
        checked = Path(args[2])
        data = json.loads(checked.read_text())
        assert isinstance(data.get("outbounds"), list), data
        if failure == "check" and "candidate" in checked.name:
            return 23
        for outbound in data["outbounds"]:
            for option in ("fragment", "record_fragment"):
                value = outbound.get("tls", {}).get(option)
                if value is not None and not isinstance(value, bool):
                    return 24
        if failure == "source_changed" and "candidate" in checked.name:
            external_write(state)
        if failure == "rollback_invalid" and "source" in checked.name:
            checks = [json.loads(line) for line in (root / "events.jsonl").read_text().splitlines()]
            if sum(record[0] == "check" and "source" in record[-1] for record in checks) > 1:
                return 24
        return 0
    if kind == "restart":
        assert args == ["restart"], args
        live = json.loads(Path(state["config"]).read_text())
        selected = state.get("uci", {})
        assert live["outbounds"][0]["tls"]["record_fragment"] == (selected.get("RECORD_FRAGMENT", "true") == "true"), live
        if failure == "restart_changed":
            external_write(state)
        return 31 if failure in ("restart", "restart_changed", "rollback_rename", "rollback_invalid") else 0
    if kind == "immediate_patch":
        return 32 if failure == "immediate_patch" else 0
    if kind == "pidof":
        return 1 if failure == "no_process" else 0
    if kind == "before":
        command, *values = args
        source = values[-2] if len(values) > 1 else ""
        target = values[-1] if values else ""
        matched = {
            "snapshot_copy": command == "cp" and "fragment-source" in target,
            "candidate_copy": command == "cp" and "fragment-candidate" in target,
            "backup_copy": command == "cp" and "fragment-backup" in target,
            "allocation": command == "mktemp",
            "backup_rename": command == "mv" and target == state["config"] + ".bak",
            "publish_rename": command == "mv" and target == state["config"] and "candidate" in source,
            "rollback_rename": command == "mv" and target == state["config"] and "source" in source,
            "wrapper_copy": command == "cp",
            "wrapper_awk": command == "awk",
            "wrapper_chmod": command == "chmod",
            "orig_rename": command == "mv" and target == state["orig"],
            "init_rename": command == "mv" and target == state["init"],
            "link": command == "ln",
            "remove_orig": command == "rm" and target == state["orig"],
        }
        if matched.get(failure, False):
            if command == "cp":
                Path(target).write_bytes(b"partial failed write")
            return 73
        if command == "mv" and target == state["init"] and state.get("pause_wrapper"):
            pause(state, "wrapper")
        if command == "awk" and state.get("pause_prepare"):
            pause(state, "prepare")
        if command == "awk" and failure == "init_changed":
            Path(state["init"]).write_text(state["external_init"])
        return 0
    raise AssertionError(kind)


class Fixture:
    def __init__(self, run, name, **settings):
        self.root = run / name
        self.root.mkdir()
        (self.root / "live").mkdir()
        self.config = self.root / "live/config.json"
        self.backup = Path(str(self.config) + ".bak")
        self.auto_backup = Path(str(self.config) + ".auto-backup")
        self.init = self.root / "live/podkop"
        self.orig = self.root / "live/podkop.orig"
        self.patch = self.root / "immediate-patch.sh"
        self.log = self.root / "fragment.log"
        self.lock = self.root / "patch.lock"
        self.wrapper_lock = self.root / "wrapper.lock"
        self.link = self.root / "S99podkop-fragment"
        self.config.write_bytes(encoded(ORIGINAL))
        self.backup.write_bytes(encoded({"previous": "valid backup"}))
        self.auto_backup.write_bytes(encoded({"editor": "keep"}))
        self.initial_backup = self.backup.read_bytes()
        self.initial_auto = self.auto_backup.read_bytes()
        self.state = {
            "root": str(self.root), "config": str(self.config), "init": str(self.init), "orig": str(self.orig),
            **settings,
        }
        self.state_path = self.root / "state.json"
        self.save_state()
        helper = "python3 " + shlex.quote(str(Path(__file__).resolve())) + " --fixture-command " + shlex.quote(str(self.state_path))
        stubs = []
        for command in ("cp", "mv", "mktemp", "chmod", "awk", "ln", "rm"):
            stubs.append(f'{command}() {{ {helper} before {command} "$@" || return $?; command {command} "$@"; }}')
        for command in ("jq", "pidof"):
            stubs.append(f'{command}() {{ {helper} {command} "$@"; }}')
        stubs.append("sleep() { :; }")
        if settings.get("without_cmp"):
            stubs.append('command() { if [ "$1" = -v ] && [ "$2" = cmp ]; then return 1; fi; /bin/sh -c \'command "$@"\' sh "$@"; }')
        self.stubs = self.root / "stubs.sh"
        self.stubs.write_text("\n".join(stubs) + "\n")
        functions = self.root / "functions.sh"
        values = {
            "ENABLED": "1", "FRAGMENT": "false", "RECORD_FRAGMENT": "true", "FALLBACK_DELAY": "500ms",
            "SINGBOX_CONFIG": str(self.config), "LOG_FILE": str(self.log), "LOG_MAX_LINES": "200",
            **settings.get("uci", {}),
        }
        functions.write_text("config_load() { :; }\nconfig_get() { :; }\n" + "\n".join(
            key + "=" + shlex.quote(value) for key, value in values.items()) + "\n")
        repo = Path(__file__).resolve().parents[1]
        writer = (repo / "usr/bin/podkop-fragment-patch.sh").read_text()
        assert writer.count(". /lib/functions.sh") == 1
        assert writer.count("sing-box check -c") == 3
        writer = writer.replace(". /lib/functions.sh", ". " + shlex.quote(str(functions)))
        writer = writer.replace("/var/lock/podkop-fragment.lock", str(self.lock))
        writer = writer.replace("/etc/init.d/sing-box", str(self.root / "service.sh"))
        writer = writer.replace("sing-box check -c", shlex.quote(str(self.root / "sing-box")) + " check -c")
        self.writer = self.root / "writer.sh"
        self.writer.write_text(writer)
        for path, action in ((self.root / "service.sh", "restart"), (self.root / "sing-box", "check"), (self.patch, "immediate_patch")):
            path.write_text(f'#!/bin/sh\nexec {helper} {action} "$@"\n')
            path.chmod(0o755)
        wrapper = (repo / "etc/init.d/podkop-fragment").read_text()
        replacements = {
            "/etc/init.d/podkop.orig": str(self.orig), "/etc/init.d/podkop": str(self.init),
            "/usr/bin/podkop-fragment-patch.sh": str(self.patch),
            "/etc/init.d/podkop-fragment": str(self.root / "fragment-init.sh"),
            "/etc/config/podkop-fragment": str(self.root / "fragment.uci"),
            "/var/log/podkop-fragment.log": str(self.log),
            "/var/lock/podkop-fragment-wrapper.lock": str(self.wrapper_lock),
            "/etc/rc.d/S99podkop-fragment": str(self.link),
        }
        # Longest first avoids replacing the /podkop prefix in /podkop-fragment.
        for old in sorted(replacements, key=len, reverse=True):
            wrapper = wrapper.replace(old, replacements[old])
        self.wrapper = self.root / "wrapper.sh"
        self.wrapper.write_text(wrapper)
        self.base = ("#!/bin/sh /etc/rc.common\nSTART=90\nCURRENT_UPSTREAM='new'\n"
                     "start_service() {\n\tprintf '%s\\n' start\n}\n"
                     "reload_service() {\n\tprintf '%s\\n' reload\n}\n"
                     "service_triggers() {\n\tcustom_trigger keep-me\n}\n"
                     "unknown_extension() {\n\t: upstream-extension\n}\n"
                     f"# Administrator reference: {self.patch}\n"
                     f"custom_hook() {{\n    ( sleep 5 && {self.patch} ) & # administrator-owned\n}}\n")
        self.init.write_text(self.base)
        self.init.chmod(0o755)
        self.children = []

    @property
    def hook(self):
        return f"\t( sleep 5 && {self.patch} ) &\n"

    def save_state(self):
        self.state_path.write_text(json.dumps(self.state))

    def with_hooks(self, count, base=None):
        return (self.base if base is None else base).replace("\n}\n", "\n" + self.hook * count + "}\n", 2)

    def spawn(self, action="writer"):
        runner = self.root / ("runner-" + str(len(self.children)) + ".sh")
        body = ". " + shlex.quote(str(self.stubs)) + "\n"
        body += ". " + shlex.quote(str(self.writer if action == "writer" else self.wrapper)) + "\n"
        if action != "writer":
            assert action in ("enable", "disable", "_install_wrapper", "_uninstall_wrapper")
            body += action + "\n"
        runner.write_text(body)
        process = subprocess.Popen(["sh", str(runner)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        self.children.append(process)
        return process

    def joined(self, process):
        out, err = process.communicate(timeout=20)
        return process.returncode, out.decode(), err.decode()

    def run(self, action="writer", success=True):
        result = self.joined(self.spawn(action))
        assert (result[0] == 0) == success, result
        self.no_owned_temps()
        return result

    def no_owned_temps(self):
        assert not self.lock.exists(), "patch lock leaked"
        assert not self.wrapper_lock.exists(), "wrapper lock leaked"
        assert not list((self.root / "live").glob("*.pt-fragment-*")), "owned temp leaked"
        assert not list(self.root.glob("*.pt-fragment.*")), "owned log temp leaked"

    def events(self, kind):
        path = self.root / "events.jsonl"
        records = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [record[1:] for record in records if record[0] == kind]

    def no_restart(self):
        assert not self.events("restart"), self.events("restart")
        assert "patch applied" not in (self.log.read_text() if self.log.exists() else "")

    def preserved_editor_backup(self):
        assert self.auto_backup.read_bytes() == self.initial_auto

    def close(self):
        for child in self.children:
            if child.poll() is None:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(child.pid, signal.SIGTERM)
            try:
                child.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.communicate(timeout=5)


def wait_for(path):
    deadline = time.monotonic() + 10
    while not path.exists():
        assert time.monotonic() < deadline, "barrier not reached: " + str(path)
        time.sleep(0.01)


class Observer:
    def __init__(self, path):
        self.path = path
        self.stop = threading.Event()
        self.errors = []
        self.reads = 0
        self.thread = threading.Thread(target=self.observe)

    def observe(self):
        # An existing reader must never see truncation, including across rename.
        # Sample new readers too. WSL/DrvFS can transiently return ENOENT during
        # native rename replacement; retry only that lookup error for <=100ms.
        # Empty/partial/invalid bytes are never retried or excused.
        missing_since = None
        with self.path.open("rb", buffering=0) as original:
            while not self.stop.is_set():
                try:
                    original.seek(0)
                    assert isinstance(json.loads(original.read()), dict)
                    assert isinstance(json.loads(self.path.read_bytes()), dict)
                    self.reads += 1
                    missing_since = None
                except FileNotFoundError as error:
                    missing_since = missing_since or time.monotonic()
                    if time.monotonic() - missing_since > 0.1:
                        self.errors.append(repr(error))
                except Exception as error:
                    self.errors.append(repr(error))
                self.stop.wait(0.001)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *unused):
        self.stop.set()
        self.thread.join()
        assert self.reads > 0 and not self.errors, (self.reads, self.errors)


def main():
    repo = Path(__file__).resolve().parents[1]
    workspace = repo.parent if repo.name == "repo" and (repo.parent / "env.md").is_file() else repo
    assert workspace.is_dir() and (repo / "usr/bin/podkop-fragment-patch.sh").is_file()
    for source in (repo / "usr/bin/podkop-fragment-patch.sh", repo / "etc/init.d/podkop-fragment", Path(__file__)):
        data = source.read_bytes()
        assert b"\r" not in data and data.endswith(b"\n"), "source must use LF: " + str(source)
    temporary = workspace / ".test_tmp"
    temporary.mkdir(exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix=time.strftime("%d.%m.%Y_%H.%M-", time.gmtime(time.time() + 3 * 3600)) + "fragment-", dir=temporary))
    fixtures = []
    checks = 0

    def fixture(name, **settings):
        value = Fixture(run, name, **settings)
        fixtures.append(value)
        return value

    try:
        f = fixture("concurrent", pause_patch=True)
        with Observer(f.config), Observer(f.backup):
            first = f.spawn()
            wait_for(f.root / "patch.ready")
            second, third = f.spawn(), f.spawn()
            assert f.joined(second)[0] != 0 and f.joined(third)[0] != 0
            assert f.config.read_bytes() == encoded(ORIGINAL)
            assert f.backup.read_bytes() == f.initial_backup
            (f.root / "patch.release").touch()
            assert f.joined(first)[0] == 0
        assert len(f.events("restart")) == 1
        assert json.loads(f.backup.read_bytes()) == ORIGINAL
        expected = json.loads(encoded(ORIGINAL))
        expected["outbounds"][0]["tls"].update(fragment=False, record_fragment=True)
        del expected["outbounds"][0]["tls"]["fragment_fallback_delay"]
        assert json.loads(f.config.read_bytes()) == expected
        f.run()  # A later generated hook sees the already-patched config.
        assert len(f.events("restart")) == 1
        f.no_owned_temps()
        f.preserved_editor_backup()
        checks += 1

        for failure in ("no_process", "allocation", "snapshot_copy", "inspect", "candidate_copy", "jq_partial", "jq_empty", "jq_invalid", "check", "backup_copy", "backup_rename", "publish_rename"):
            f = fixture("failure-" + failure, failure=failure)
            with Observer(f.config), Observer(f.backup):
                f.run(success=False)
            assert f.config.read_bytes() == encoded(ORIGINAL), failure
            assert f.backup.read_bytes() == (encoded(ORIGINAL) if failure == "publish_rename" else f.initial_backup), failure
            f.preserved_editor_backup()
            f.no_restart()
            checks += 1

        for number, source in enumerate((b"", b" \n\t", b'{"outbounds":', b"false", b"{}\n{}\n")):
            f = fixture("invalid-source-" + str(number))
            f.config.write_bytes(source)
            f.run(success=False)
            assert f.config.read_bytes() == source and f.backup.read_bytes() == f.initial_backup
            f.preserved_editor_backup()
            f.no_restart()
            checks += 1

        for without_cmp in (False, True):
            f = fixture("source-changed-" + str(without_cmp), failure="source_changed", without_cmp=without_cmp)
            f.run(success=False)
            assert json.loads(f.config.read_bytes()) == EXTERNAL
            assert f.backup.read_bytes() == f.initial_backup
            f.no_restart()
            checks += 1

        for failure in ("restart", "rollback_rename", "rollback_invalid", "restart_changed"):
            f = fixture("restart-" + failure, failure=failure)
            with Observer(f.config):
                f.run(success=False)
            assert len(f.events("restart")) == 1
            assert json.loads(f.backup.read_bytes()) == ORIGINAL
            live = json.loads(f.config.read_bytes())
            if failure == "restart":
                assert live == ORIGINAL and "previous config restored atomically" in f.log.read_text()
            elif failure == "restart_changed":
                assert live == EXTERNAL
            else:
                assert live["outbounds"][0]["tls"]["record_fragment"] is True
            assert "patch applied" not in f.log.read_text()
            assert "service state unverified" in f.log.read_text()
            f.preserved_editor_backup()
            checks += 1

        for fragment, record in (("true", "true"), ("true", "false")):
            f = fixture("semantics-" + record, uci={"FRAGMENT": fragment, "RECORD_FRAGMENT": record, "FALLBACK_DELAY": "750ms"})
            f.run()
            tls = json.loads(f.config.read_bytes())["outbounds"][0]["tls"]
            assert tls["fragment"] is True and tls["record_fragment"] == (record == "true") and tls["fragment_fallback_delay"] == "750ms"
            checks += 1

        for name, uci in (("disabled", {"ENABLED": "0"}), ("both-off", {"FRAGMENT": "false", "RECORD_FRAGMENT": "false"})):
            f = fixture(name, uci=uci)
            f.run()
            assert f.config.read_bytes() == encoded(ORIGINAL) and f.backup.read_bytes() == f.initial_backup
            f.no_restart()
            checks += 1

        for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            f = fixture("signal-" + sig.name, pause_patch=True)
            process = f.spawn()
            wait_for(f.root / "patch.ready")
            os.killpg(process.pid, sig)
            assert f.joined(process)[0] != 0
            f.no_owned_temps()
            assert f.config.read_bytes() == encoded(ORIGINAL) and f.backup.read_bytes() == f.initial_backup
            f.no_restart()
            checks += 1

        f = fixture("wrapper-repeat")
        f.init.write_text(f.with_hooks(3))
        f.orig.write_text(f.with_hooks(4, f.base.replace("'new'", "'old'")))
        for _ in range(3):
            # The API's explicit Reinstall maps to this same enable operation.
            f.run("enable")
            assert f.init.read_text() == f.with_hooks(1)
            assert f.orig.read_text() == f.base
            assert f.init.stat().st_mode & 0o111 and f.orig.stat().st_mode & 0o111
        added = "\nnew_upstream_function() {\n\t: keep-latest\n}\n"
        f.init.write_text(f.init.read_text() + added)
        f.run("disable")
        assert f.init.read_text() == f.base + added and not f.orig.exists() and not f.link.exists()
        checks += 1

        f = fixture("wrapper-whitespace")
        spaced = f.with_hooks(3).replace(f.hook, "    " + f.hook.strip() + "  \t\n")
        f.init.write_text(spaced)
        f.orig.write_text(spaced)
        f.run("enable")
        assert f.init.read_text() == f.with_hooks(1) and f.orig.read_text() == f.base
        f.run("disable")
        assert f.init.read_text() == f.base and not f.orig.exists()
        checks += 1

        f = fixture("wrapper-custom-identical")
        custom = "\ncustom_refresh() {\n\tlogger keep-custom-function\n" + f.hook + "}\n"
        baseline = f.base + custom
        f.init.write_text(f.with_hooks(3) + custom)
        f.orig.write_text(f.with_hooks(4) + custom)
        f.run("enable")
        assert f.init.read_text() == f.with_hooks(1) + custom and f.orig.read_text() == baseline
        f.run("disable")
        assert f.init.read_text() == baseline and not f.orig.exists()
        checks += 1

        f = fixture("source-invalid-service-config")
        invalid = json.loads(encoded(ORIGINAL))
        invalid["outbounds"][0]["tls"]["fragment"] = "broken"
        f.config.write_bytes(encoded(invalid))
        f.run(success=False)
        assert f.config.read_bytes() == encoded(invalid) and f.backup.read_bytes() == f.initial_backup
        assert "source config failed sing-box check" in f.log.read_text()
        f.no_restart()
        f.preserved_editor_backup()
        checks += 1

        f = fixture("wrapper-stale")
        f.orig.write_text(f.with_hooks(3, f.base.replace("'new'", "'old'")))
        fresh = f.base.replace("'new'", "'fresh-package'").rstrip("\n")
        f.init.write_text(fresh)
        before = f.init.stat()
        f.run("disable")
        after = f.init.stat()
        assert f.init.read_text() == fresh and (before.st_ino, before.st_mtime_ns) == (after.st_ino, after.st_mtime_ns)
        assert not f.orig.exists()
        f.run("enable")
        assert "fresh-package" in f.orig.read_text() and f.init.read_text().count(f.hook) == 2
        checks += 1

        f = fixture("wrapper-no-original")
        f.init.write_text(f.with_hooks(3))
        f.run("disable")
        assert f.init.read_text() == f.base and not f.orig.exists()
        checks += 1

        for failure in ("wrapper_copy", "wrapper_awk", "wrapper_chmod", "orig_rename", "init_rename", "init_changed", "link", "immediate_patch"):
            f = fixture("wrapper-failure-" + failure, failure=failure)
            f.init.write_text(f.with_hooks(3))
            previous_orig = f.with_hooks(4)
            f.orig.write_text(previous_orig)
            f.state["external_init"] = f.base + "\nexternal_edit() { :; }\n"
            f.save_state()
            result = f.run("enable", success=False)
            assert "podkop-fragment enabled and wrapper installed" not in result[1]
            if failure == "init_changed":
                assert f.init.read_text() == f.state["external_init"]
            elif failure in ("link", "immediate_patch"):
                assert f.init.read_text() == f.with_hooks(1)
            else:
                assert f.init.read_text() == f.with_hooks(3)
            if failure in ("init_rename", "link", "immediate_patch"):
                assert f.orig.read_text() == f.base
            else:
                assert f.orig.read_text() == previous_orig
            checks += 1

        for invalid in ("start_service() {\n", "start_service() { :; }\n"):
            f = fixture("wrapper-invalid-" + str(checks))
            f.init.write_text(invalid)
            f.orig.write_text("old original\n")
            f.run("enable", success=False)
            assert f.init.read_text() == invalid and f.orig.read_text() == "old original\n"
            assert not f.link.exists()
            checks += 1

        for failure in ("init_rename", "wrapper_chmod", "remove_orig"):
            f = fixture("disable-failure-" + failure, failure=failure)
            f.init.write_text(f.with_hooks(3))
            f.orig.write_text(f.with_hooks(4))
            result = f.run("disable", success=False)
            assert "podkop-fragment disabled and wrapper removed" not in result[1]
            assert f.init.read_text() == (f.base if failure == "remove_orig" else f.with_hooks(3))
            assert f.orig.read_text() == f.with_hooks(4)
            checks += 1

        f = fixture("wrapper-concurrent", pause_prepare=True)
        first = f.spawn("enable")
        wait_for(f.root / "prepare.ready")
        result = f.joined(f.spawn("enable"))
        assert result[0] != 0 and "lock busy" in result[1]
        (f.root / "prepare.release").touch()
        assert f.joined(first)[0] == 0
        assert f.init.read_text() == f.with_hooks(1) and f.orig.read_text() == f.base
        f.no_owned_temps()
        checks += 1

        for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            f = fixture("wrapper-signal-" + sig.name, pause_prepare=True)
            process = f.spawn("enable")
            wait_for(f.root / "prepare.ready")
            os.killpg(process.pid, sig)
            assert f.joined(process)[0] != 0
            f.no_owned_temps()
            assert f.init.read_text() == f.base and not f.orig.exists() and not f.link.exists()
            checks += 1

        f = fixture("wrapper-interrupted-after-original", pause_wrapper=True)
        f.init.write_text(f.with_hooks(3))
        f.orig.write_text(f.with_hooks(4))
        process = f.spawn("enable")
        wait_for(f.root / "wrapper.ready")
        os.killpg(process.pid, signal.SIGTERM)
        assert f.joined(process)[0] != 0
        f.no_owned_temps()
        assert f.init.read_text() == f.with_hooks(3) and f.orig.read_text() == f.base and not f.link.exists()
        checks += 1
    except BaseException:
        print("Fragment regression failed; owned fixtures retained: " + str(run), file=sys.stderr)
        raise
    finally:
        for f in fixtures:
            f.close()

    shutil.rmtree(run)
    print(f"Native Fragment lifecycle: PASS ({checks} scenarios; real POSIX shell/atomic files/concurrency/signals; controlled JSON/service/IO stubs)")
    print("Cleanup: joined all owned subprocesses/observers and removed the unique .test_tmp run; no router/services/PATH changes")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--fixture-command":
        sys.exit(fixture_command(sys.argv[2], sys.argv[3], sys.argv[4:]))
    main()
