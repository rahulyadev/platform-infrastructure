#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

if ((EUID != 0)); then
  printf '%s\n' 'portfolio rollback must run as root' >&2
  exit 1
fi

readonly target_release_id="${SSM_TargetReleaseID:-}"
[[ "$target_release_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]

readonly releases_root=/srv/platform/portfolio/releases
readonly current_link=/srv/platform/portfolio/current
readonly state_root=/srv/platform/portfolio/deployment-state
readonly target_release="$releases_root/$target_release_id"
readonly target_manifest="$target_release/.platform-manifest.json"
readonly previous_target="$(readlink -f "$current_link" 2>/dev/null || true)"
activated=0

[[ -d "$target_release" ]]
[[ ! -L "$target_release" ]]
[[ -f "$target_manifest" ]]
case "$target_release" in
  "$releases_root"/*) ;;
  *) printf '%s\n' 'rollback target escaped the release root' >&2; exit 1 ;;
esac

restore_previous() {
  if ((activated == 1)) && [[ -n "$previous_target" ]] && [[ -d "$previous_target" ]]; then
    local restore_link="${current_link}.restore.$$"
    ln -s "$previous_target" "$restore_link"
    mv -Tf "$restore_link" "$current_link"
    if nginx -t; then
      systemctl reload nginx.service
    fi
  fi
}

on_exit() {
  local status=$?
  if ((status != 0)); then
    restore_previous
  fi
  exit "$status"
}
trap on_exit EXIT

python3 - "$target_release" "$target_manifest" "$target_release_id" <<'PYTHON'
import hashlib
import json
from pathlib import Path, PurePosixPath
import sys

root = Path(sys.argv[1])
manifest = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
release_id = sys.argv[3]

if manifest.get("schemaVersion") != 1 or manifest.get("release", {}).get("id") != release_id:
    raise SystemExit("rollback manifest identity mismatch")

entries = manifest.get("files", [])
if not entries:
    raise SystemExit("rollback manifest has no files")

for entry in entries:
    relative = entry.get("path", "")
    pure = PurePosixPath(relative)
    if (
        pure.is_absolute()
        or relative != pure.as_posix()
        or ".." in pure.parts
        or any(ord(character) < 32 or ord(character) == 127 for character in relative)
    ):
        raise SystemExit("unsafe rollback manifest path")
    target = root / relative
    if not target.is_file() or target.is_symlink():
        raise SystemExit("rollback release file is missing or unsafe")
    if target.stat().st_size != entry.get("size"):
        raise SystemExit("rollback release size mismatch")
    if hashlib.sha256(target.read_bytes()).hexdigest() != entry.get("sha256"):
        raise SystemExit("rollback release hash mismatch")

required = {"index.html", "__spa-fallback.html", "rss.xml", "sitemap.xml", "robots.txt"}
if not required.issubset({entry["path"] for entry in entries}):
    raise SystemExit("rollback release is missing required files")
PYTHON

next_link="${current_link}.next.$$"
ln -s "$target_release" "$next_link"
mv -Tf "$next_link" "$current_link"
activated=1

nginx -t
systemctl reload nginx.service
/usr/local/lib/platform/smoke-portfolio.sh http://127.0.0.1 "$current_link"

state_file="$state_root/current-release.json"
state_temporary="${state_file}.next.$$"
printf '{"releaseId":"%s","rollbackAt":"%s"}\n' \
  "$target_release_id" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$state_temporary"
chown root:nginx "$state_temporary"
chmod 0440 "$state_temporary"
mv -f -- "$state_temporary" "$state_file"

printf 'rollback to %s completed at %s\n' "$target_release_id" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
