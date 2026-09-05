#!/usr/bin/env python3
"""Render and execute the exact SSM diagnostic using canonical units and synthetic commands."""
import argparse
import base64
import gzip
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile


REPOSITORY = pathlib.Path(__file__).resolve().parents[2]


def render() -> str:
    template = (REPOSITORY / "tests/runtime/identity-configure-diagnostic.sh").read_text()
    configure = (REPOSITORY / "deploy/ssm/configure-identity-runtime.sh.tftpl").read_text()
    verifier = configure.split("verify_staged_units() (", 1)[1].split("\nif [[", 1)[0]
    transformer = verifier.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0] + "\n"
    values = {"__TASK007_TRANSFORMER_B64__": base64.b64encode(transformer.encode()).decode()}
    for key, name in (("DOCKER", "docker.service"), ("IDENTITY", "identity-stack.service")):
        value = (REPOSITORY / "config/runtime" / name).read_bytes()
        values[f"__TASK007_{key}_UNIT_B64GZIP__"] = base64.b64encode(gzip.compress(value, mtime=0)).decode()
    for marker, value in values.items():
        assert template.count(marker) == 1
        template = template.replace(marker, value)
    assert "__TASK007_" not in template
    return template


def test_rendered() -> None:
    rendered = render()
    # Round-trip the exact JSON string used by SSM, preserving all heredoc and quoting bytes.
    rendered = json.loads(json.dumps({"commands": [rendered]}))["commands"][0]
    before = set(pathlib.Path("/tmp").glob("platform-task007-unit.*"))
    for defect in ("none", "non-executable"):
        environment = {**os.environ, "TASK007_TEST_DEFECT": defect}
        result = subprocess.run(
            ["bash", "-s", "--", "--local-fixture"], input=rendered,
            text=True, capture_output=True, env=environment, check=False,
        )
        assert not result.stderr, hashlib.sha256(result.stderr.encode()).hexdigest()
        assert "DIAGNOSTIC_CLEANUP=PASS\n" in result.stdout
        assert set(pathlib.Path("/tmp").glob("platform-task007-unit.*")) == before
        if defect == "none":
            assert result.returncode == 0
            assert "UNIT_TRANSFORM_STATUS=0\n" in result.stdout
            assert "SYSTEMD_YES_STATUS=0\n" in result.stdout
            assert "SYSTEMD_NO_STATUS=0\n" in result.stdout
            assert "MANAGED_UNITS=2\nCOMMAND_TOKEN_OCCURRENCES=4\nUNIQUE_EXECUTABLES=3\n" in result.stdout
        else:
            assert result.returncode == 2
            assert "UNIT_TRANSFORM_STATUS=2\n" in result.stdout
            assert "SYSTEMD_YES_STATUS" not in result.stdout
        print(json.dumps({"fixture": defect, "status": result.returncode, "cleanup": "PASS", "rendered_sha256": hashlib.sha256(rendered.encode()).hexdigest()}))


def observation_case(source: str, defect: str) -> None:
    """Measure real child captures independently, then verify the pre-cleanup report."""
    with tempfile.TemporaryDirectory(prefix="identity-unit-observation.") as temporary:
        root = pathlib.Path(temporary)
        active = root / "active"
        verification = root / "verification"
        verification.mkdir(mode=0o700)
        units = active / "etc/systemd/system"
        units.mkdir(parents=True)
        canonical = {}
        for name in ("docker.service", "identity-stack.service"):
            value = (REPOSITORY / "config/runtime" / name).read_bytes()
            if defect == "direct-syntax" and name == "docker.service":
                value = value.replace(b"Type=notify\n", b"Type=definitely-invalid\n")
            canonical[name] = base64.b64encode(gzip.compress(value, mtime=0)).decode()
            target = units / name
            target.write_bytes(value)
            target.chmod(0o644)
        for relative in ("usr/local/bin/dockerd", "usr/local/libexec/platform/identity-verify-release",
                         "usr/local/lib/docker/cli-plugins/docker-compose"):
            target = active / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("#!/bin/sh\nexit 0\n")
            target.chmod(0o755)
        if defect == "missing-command":
            (active / "usr/local/bin/dockerd").unlink()
        adapters = root / "bin"
        adapters.mkdir()
        # Each adapter invokes the real tool and forwards its exact status/streams.
        # The independent oracle is outside the verifier's cleanup tree.
        for name, executable in (("python3", sys.executable), ("systemd-analyze", shutil.which("systemd-analyze"))):
            assert executable
            adapter = adapters / name
            adapter.write_text(
                f"#!{sys.executable}\nimport os,pathlib,subprocess,sys\n"
                f"result=subprocess.run([{executable!r},*sys.argv[1:]],input=sys.stdin.buffer.read(),capture_output=True)\n"
                "args=sys.argv[1:]\n"
                f"record={name == 'systemd-analyze'!r} or (len(args)>1 and args[1]=={str(active)!r})\n"
                "if record:\n"
                f"    root=pathlib.Path({str(root)!r})\n"
                f"    (root/{(name + '.stdout')!r}).write_bytes(result.stdout)\n"
                f"    (root/{(name + '.stderr')!r}).write_bytes(result.stderr)\n"
                f"    (root/{(name + '.status')!r}).write_text(str(result.returncode))\n"
                "sys.stdout.buffer.write(result.stdout);sys.stderr.buffer.write(result.stderr)\n"
                "raise SystemExit(result.returncode)\n"
            )
            adapter.chmod(0o755)
        # Reproduce the production inherited-ERR cleanup ordering without live paths.
        call = '  verify_staged_units \\\n    "$fixture_root/active"'
        assert source.count(call) == 1
        source = source.replace(call, '''  inherited_fixture_failure() {
    local status=$?
    trap - ERR
    rm -rf -- "$fixture_root/verification"
    exit "$status"
  }
  trap inherited_fixture_failure ERR
''' + call)
        environment = {**os.environ, "PATH": str(adapters) + os.pathsep + os.environ["PATH"],
                       "PLATFORM_IDENTITY_UNIT_VERIFICATION_TEST_ROOT": str(root),
                       "PLATFORM_IDENTITY_DOCKER_UNIT_B64GZIP": canonical["docker.service"],
                       "PLATFORM_IDENTITY_STACK_UNIT_B64GZIP": canonical["identity-stack.service"]}
        result = subprocess.run(["bash", "-s", "--", "--unit-verification-fixture"],
                                input=source.replace("$${", "${"), text=True, capture_output=True,
                                env=environment, check=False)
        assert not verification.exists() and not verification.is_symlink()
        assert result.returncode != 0 and not result.stdout
        fields = dict(re.findall(r"([a-z_][a-z0-9_]*)=([A-Z_0-9a-f]+)", result.stderr))
        tool = "python3" if defect == "missing-command" else "systemd-analyze"
        expected = {"stage": "UNIT_TRANSFORM" if defect == "missing-command" else "UNIT_SYSTEMD",
                    "status": (root / (tool + ".status")).read_text()}
        assert int(expected["status"]) == result.returncode
        for label in ("stdout", "stderr"):
            value = (root / f"{tool}.{label}").read_bytes()
            expected.update({f"{label}_bytes": str(len(value)), f"{label}_lines": str(len(value.splitlines())),
                             f"{label}_sha256": hashlib.sha256(value).hexdigest()})
        assert fields == expected
        assert result.stderr == "IDENTITY_CONFIGURE_FAILURE " + " ".join(f"{k}={v}" for k, v in expected.items()) + "\n"


def test_failure_observation() -> None:
    source = (REPOSITORY / "deploy/ssm/configure-identity-runtime.sh.tftpl").read_text()
    for defect in ("missing-command", "direct-syntax"):
        observation_case(source, defect)
        print(json.dumps({"fixture": defect, "real_capture_identity": "PASS", "cleanup": "PASS"}))
    mutations = {
        "inherited-early-cleanup": ("  trap - ERR\n  local active_root", "  local active_root"),
        "lost-status": ('    [[ ! -e "$verification_root" && ! -L "$verification_root" ]]\n    exit "$status"',
                        '    [[ ! -e "$verification_root" && ! -L "$verification_root" ]]\n    exit 0'),
        "suppressed-observation": ('      report_configure_failure "$verification_stage" "$status" "$verification_stdout" "$verification_stderr"', '      :'),
        "forged-hash": ('f"{label}_sha256={hashlib.sha256(value).hexdigest()}"', 'f"{label}_sha256={hashlib.sha256(b\'forged\').hexdigest()}"'),
    }
    for name, (before, after) in mutations.items():
        assert source.count(before) == 1
        try:
            observation_case(source.replace(before, after), "missing-command")
        except (AssertionError, FileNotFoundError):
            print(json.dumps({"mutation": name, "rejected": True}))
        else:
            raise AssertionError("Failure-observation mutation was not detected: " + name)


def test_directory_metadata() -> None:
    source = (REPOSITORY / "deploy/ssm/configure-identity-runtime.sh.tftpl").read_text()
    start = source.index("directory_exact() {")
    end = source.index("\n}\n", start) + 3
    function = source[start:end].replace("$${", "${")
    # This is the existing runtime fixture image, with no new image or dependency.
    image = json.loads((REPOSITORY / "config/runtime/identity-images.json").read_text())["postgres"]["image"]
    fixture = '''
set -Eeuo pipefail
umask 077
root="$(mktemp -d /tmp/platform-identity-directory.XXXXXX)"
trap 'rm -rf -- "$root"' EXIT
candidate="$root/candidate"
must_reject() {
  if directory_exact "$1" "$2"; then exit 9; fi
}
install -d -m 0755 "$candidate"
directory_exact "$candidate" 0755
printf 'DECLARED_0755=PASS\n'
chmod 0700 "$candidate"
directory_exact "$candidate" 0700
printf 'DECLARED_0700=PASS\n'
chmod 0750 "$candidate"
must_reject "$candidate" 0755
printf 'WRONG_MODE=REJECTED\n'
chmod 0755 "$candidate"
chown 1:0 "$candidate"
must_reject "$candidate" 0755
chown 0:1 "$candidate"
must_reject "$candidate" 0755
chown 0:0 "$candidate"
printf 'WRONG_OWNER_GROUP=REJECTED\n'
ln -s "$candidate" "$root/symlink"
must_reject "$root/symlink" 0755
install -m 0755 /dev/null "$root/file"
must_reject "$root/file" 0755
must_reject "$root/absent" 0755
printf 'SYMLINK_FILE_ABSENT=REJECTED\n'
'''
    expected = ("DECLARED_0755=PASS\nDECLARED_0700=PASS\nWRONG_MODE=REJECTED\n"
                "WRONG_OWNER_GROUP=REJECTED\nSYMLINK_FILE_ABSENT=REJECTED\n")
    arguments = ["docker", "run", "--rm", "--network", "none", "--read-only", "--user", "0:0",
                 "--cap-drop", "ALL", "--cap-add", "CHOWN", "--cap-add", "FOWNER",
                 "--security-opt", "no-new-privileges", "--tmpfs", "/tmp:rw,nosuid,nodev",
                 "--interactive", "--entrypoint", "/bin/bash", image, "-s"]
    result = subprocess.run(arguments, input=function + fixture, text=True, capture_output=True)
    assert result.returncode == 0 and not result.stderr and result.stdout == expected, json.dumps({
        "fixture": "declared-directory-mode", "status": result.returncode,
        "stdout_bytes": len(result.stdout), "stderr_sha256": hashlib.sha256(result.stderr.encode()).hexdigest()})
    assert "${mode#0}" in function
    for name, mutant in (
        ("leading-zero-string-comparison", function.replace("${mode#0}", "$mode")),
        ("ignored-owner", function.replace(":0:0", ":$(stat -c '%u:%g' \"$directory\")")),
    ):
        rejected = subprocess.run(arguments, input=mutant + fixture, text=True, capture_output=True)
        assert rejected.returncode != 0 or rejected.stdout != expected
        print(json.dumps({"directory_mutation": name, "rejected": True}))
    print(json.dumps({"fixture": "declared-directory-modes", "root_owner_group_mode_type": "PASS"}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--render", action="store_true")
    parser.add_argument("--directory-fixture", action="store_true")
    args = parser.parse_args()
    if args.render:
        print(render(), end="")
    elif args.directory_fixture:
        test_directory_metadata()
    else:
        test_rendered()
        test_failure_observation()
        test_directory_metadata()
