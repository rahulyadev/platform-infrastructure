#!/usr/bin/env bash
# Render the three source-derived payloads with test-identity-configure-diagnostic.py.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
set +x

readonly diagnostic_mode="${1:-host}"
readonly expected_uid="$(id -u)"
readonly expected_gid="$(id -g)"
[[ "$diagnostic_mode" == --local-fixture || "$expected_uid:$expected_gid" == 0:0 ]]
readonly diagnostic_root="$(mktemp -d /tmp/platform-task007-unit.XXXXXX)"
readonly active_root="$diagnostic_root/active"
readonly copies_root="$diagnostic_root/copies"
readonly captures_root="$diagnostic_root/captures"
stage=INITIALIZATION

finish() {
  local status="$?"
  trap - EXIT ERR
  set +e
  if [[ "$status" != 0 ]]; then
    printf 'DIAGNOSTIC_STAGE=%s\nDIAGNOSTIC_STATUS=%s\n' "$stage" "$status"
  fi
  rm -rf -- "$diagnostic_root"
  if [[ -e "$diagnostic_root" || -L "$diagnostic_root" ]]; then
    printf 'DIAGNOSTIC_CLEANUP=FAILED\n'
    exit 1
  fi
  printf 'DIAGNOSTIC_CLEANUP=PASS\n'
  exit "$status"
}
trap finish EXIT
[[ -d "$diagnostic_root" && ! -L "$diagnostic_root" ]]
[[ "$(stat -c '%a:%u:%g' "$diagnostic_root")" == "700:$expected_uid:$expected_gid" ]]
install -d -m 0700 "$active_root/etc/systemd/system" "$active_root/usr/local/bin" \
  "$active_root/usr/local/libexec/platform" "$active_root/usr/local/lib/docker/cli-plugins" \
  "$copies_root" "$captures_root"

decode_unit() {
  local encoded="$1" destination="$2"
  local temporary
  temporary="$destination.next"
  install -m 0600 /dev/null "$temporary"
  printf '%s' "$encoded" | base64 --decode | gzip --decompress >"$temporary"
  chmod 0644 "$temporary"
  mv -Tf -- "$temporary" "$destination"
}

readonly docker_payload='__TASK007_DOCKER_UNIT_B64GZIP__'
readonly identity_payload='__TASK007_IDENTITY_UNIT_B64GZIP__'
stage=CANONICAL_PAYLOADS
decode_unit "$docker_payload" "$active_root/etc/systemd/system/docker.service"
decode_unit "$identity_payload" "$active_root/etc/systemd/system/identity-stack.service"
for executable in usr/local/bin/dockerd usr/local/libexec/platform/identity-verify-release \
  usr/local/lib/docker/cli-plugins/docker-compose; do
  printf '#!/bin/sh\nexit 0\n' >"$active_root/$executable"
  chmod 0755 "$active_root/$executable"
done
# Only local synthetic execution accepts a deliberately broken executable fixture.
if [[ "$diagnostic_mode" == --local-fixture && "${TASK007_TEST_DEFECT:-none}" == non-executable ]]; then
  chmod 0644 "$active_root/usr/local/bin/dockerd"
fi

printf '%s' '__TASK007_TRANSFORMER_B64__' | base64 --decode >"$diagnostic_root/transform.py"
stage=UNIT_TRANSFORM
set +e
python3 "$diagnostic_root/transform.py" "$active_root" "$copies_root" \
  "$expected_uid" "$expected_gid" "$docker_payload" "$identity_payload" \
  >"$captures_root/transform.stdout" 2>"$captures_root/transform.stderr"
transform_status=$?
set -e

metrics() {
  local label="$1" status="$2" capture="$3"
  printf '%s_STATUS=%s\n' "$label" "$status"
  printf '%s_BYTES=%s\n' "$label" "$(wc -c <"$capture" | tr -d ' ')"
  printf '%s_LINES=%s\n' "$label" "$(wc -l <"$capture" | tr -d ' ')"
  printf '%s_SHA256=%s\n' "$label" "$(sha256sum "$capture" | cut -d' ' -f1)"
}
metrics UNIT_TRANSFORM "$transform_status" "$captures_root/transform.stderr"
[[ "$transform_status" == 0 ]] || exit "$transform_status"
printf 'MANAGED_UNITS=2\nCOMMAND_TOKEN_OCCURRENCES=4\nUNIQUE_EXECUTABLES=3\n'
sha256sum "$copies_root/docker.service" "$copies_root/identity-stack.service" >"$diagnostic_root/copies.sha256"

run_verify() {
  local recursive="$1" status
  stage="SYSTEMD_$recursive"
  set +e
  systemd-analyze --recursive-errors="$recursive" verify \
    "$copies_root/docker.service" "$copies_root/identity-stack.service" \
    >"$captures_root/systemd-$recursive.stdout" 2>"$captures_root/systemd-$recursive.stderr"
  status=$?
  set -e
  metrics "SYSTEMD_${recursive^^}" "$status" "$captures_root/systemd-$recursive.stderr"
  printf 'SYSTEMD_%s_STDOUT_BYTES=%s\n' "${recursive^^}" "$(wc -c <"$captures_root/systemd-$recursive.stdout" | tr -d ' ')"
  printf '%s' "$status" >"$captures_root/$recursive.status"
}
run_verify yes
run_verify no
sha256sum --check --status "$diagnostic_root/copies.sha256"
stage=VALUE_FREE_CLASSIFICATION
python3 - "$captures_root" <<'PY'
import json
import pathlib
import re
import subprocess
import sys

captures = pathlib.Path(sys.argv[1])
statuses = {mode: int((captures / f"{mode}.status").read_text()) for mode in ("yes", "no")}
classes = {}
for mode in statuses:
    text = (captures / f"systemd-{mode}.stderr").read_text(errors="replace")
    classes[mode] = {
        "command_not_executable": len(re.findall(r"Command .* is not executable", text)),
        "missing_path": text.count("No such file or directory"),
        "unknown_directive": len(re.findall(r"Unknown (?:key|lvalue|section|assignment)", text, re.I)),
    }
version = subprocess.check_output(["systemd-analyze", "--version"], text=True).splitlines()[0]
if not re.fullmatch(r"systemd [0-9]+ \([A-Za-z0-9_.+~ -]+\)", version):
    raise SystemExit(2)
print(json.dumps({"systemd_version": version, "statuses": statuses, "error_classes": classes}, sort_keys=True))
PY
printf 'DIAGNOSTIC_STAGE=COMPLETED\nDIAGNOSTIC_STATUS=0\n'
