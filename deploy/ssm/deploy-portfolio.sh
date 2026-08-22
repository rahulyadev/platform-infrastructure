#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

if ((EUID != 0)); then
  printf '%s\n' 'portfolio deployment must run as root' >&2
  exit 1
fi

readonly artifact_bucket="${SSM_ArtifactBucket:-}"
readonly artifact_key="${SSM_ArtifactKey:-}"
readonly artifact_sha256="${SSM_ArtifactSHA256:-}"
readonly manifest_key="${SSM_ManifestKey:-}"
readonly manifest_sha256="${SSM_ManifestSHA256:-}"
readonly release_id="${SSM_ReleaseID:-}"

[[ "$artifact_bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]
[[ "$artifact_key" =~ ^portfolio/[A-Za-z0-9][A-Za-z0-9._/-]{0,500}[A-Za-z0-9]$ ]]
[[ "$manifest_key" =~ ^portfolio/[A-Za-z0-9][A-Za-z0-9._/-]{0,500}[A-Za-z0-9]$ ]]
[[ "$artifact_sha256" =~ ^[0-9a-f]{64}$ ]]
[[ "$manifest_sha256" =~ ^[0-9a-f]{64}$ ]]
[[ "$release_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]

for key in "$artifact_key" "$manifest_key"; do
  [[ "/$key/" != *"/../"* ]]
  [[ "$key" != /* ]]
  [[ "$key" != *//* ]]
done

readonly releases_root=/srv/platform/portfolio/releases
readonly current_link=/srv/platform/portfolio/current
readonly state_root=/srv/platform/portfolio/deployment-state
readonly release_dir="$releases_root/$release_id"
readonly deployment_log=/var/log/platform/deployment.log
readonly work_dir="$(mktemp -d /var/lib/platform/deploy.XXXXXX)"
readonly artifact_path="$work_dir/artifact.tar.gz"
readonly manifest_path="$work_dir/manifest.json"
readonly extracted_path="$work_dir/extracted"
readonly previous_target="$(readlink -f "$current_link" 2>/dev/null || true)"
activated=0

install -d -o root -g root -m 0750 "$(dirname "$deployment_log")"
touch "$deployment_log"
chown root:root "$deployment_log"
chmod 0640 "$deployment_log"
exec > >(tee -a "$deployment_log") 2>&1

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

cleanup() {
  local status=$?
  if ((status != 0)); then
    restore_previous
  fi
  rm -rf -- "$work_dir"
  exit "$status"
}
trap cleanup EXIT

[[ ! -e "$release_dir" ]]
case "$release_dir" in
  "$releases_root"/*) ;;
  *) printf '%s\n' 'release path escaped the release root' >&2; exit 1 ;;
esac

printf 'deployment %s started at %s\n' "$release_id" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
aws s3 cp --only-show-errors "s3://${artifact_bucket}/${artifact_key}" "$artifact_path"
aws s3 cp --only-show-errors "s3://${artifact_bucket}/${manifest_key}" "$manifest_path"

[[ "$(sha256sum "$artifact_path" | awk '{print $1}')" == "$artifact_sha256" ]]
[[ "$(sha256sum "$manifest_path" | awk '{print $1}')" == "$manifest_sha256" ]]

python3 - "$artifact_path" "$manifest_path" "$extracted_path" "$release_id" "$artifact_sha256" <<'PYTHON'
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import tarfile

artifact_path = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
destination = Path(sys.argv[3])
release_id = sys.argv[4]
artifact_sha256 = sys.argv[5]

manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
if manifest.get("schemaVersion") != 1:
    raise SystemExit("unsupported artifact manifest schema")
if manifest.get("release", {}).get("id") != release_id:
    raise SystemExit("release identity mismatch")
if manifest.get("artifact", {}).get("sha256") != artifact_sha256:
    raise SystemExit("artifact hash does not match the signed manifest")

entries = manifest.get("files")
if not isinstance(entries, list) or not entries:
    raise SystemExit("artifact manifest has no files")

expected = {}
for entry in entries:
    path = entry.get("path")
    if not isinstance(path, str) or path in expected:
        raise SystemExit("invalid or duplicate manifest path")
    pure = PurePosixPath(path)
    if (
        pure.is_absolute()
        or path != pure.as_posix()
        or ".." in pure.parts
        or any(ord(character) < 32 or ord(character) == 127 for character in path)
    ):
        raise SystemExit("unsafe manifest path")
    if not isinstance(entry.get("size"), int) or entry["size"] < 0:
        raise SystemExit("invalid manifest size")
    if not isinstance(entry.get("sha256"), str) or len(entry["sha256"]) != 64:
        raise SystemExit("invalid manifest hash")
    expected[path] = entry

required = {"index.html", "__spa-fallback.html", "rss.xml", "sitemap.xml", "robots.txt"}
if not required.issubset(expected):
    raise SystemExit("artifact is missing required static files")
if not any(path.endswith(".data") for path in expected):
    raise SystemExit("artifact has no route data files")

destination.mkdir(mode=0o700)
seen_files = set()
seen_members = set()

with tarfile.open(artifact_path, mode="r:gz") as archive:
    for member in archive.getmembers():
        normalized = PurePosixPath(member.name).as_posix()
        while normalized.startswith("./"):
            normalized = normalized[2:]
        if normalized in ("", "."):
            if not member.isdir():
                raise SystemExit("invalid archive root member")
            continue
        path = PurePosixPath(normalized)
        if (
            path.is_absolute()
            or ".." in path.parts
            or normalized in seen_members
            or any(ord(character) < 32 or ord(character) == 127 for character in normalized)
        ):
            raise SystemExit("unsafe or duplicate archive member")
        seen_members.add(normalized)
        if member.uid != 0 or member.gid != 0:
            raise SystemExit("archive ownership is not normalized")
        if member.isdir():
            if stat.S_IMODE(member.mode) != 0o755:
                raise SystemExit("archive directory mode is not normalized")
            (destination / normalized).mkdir(parents=True, exist_ok=True, mode=0o755)
            continue
        if not member.isfile():
            raise SystemExit("archive contains a link, device, socket, or FIFO")
        if stat.S_IMODE(member.mode) != 0o644:
            raise SystemExit("archive file mode is not normalized")
        if normalized not in expected:
            raise SystemExit("archive file is absent from the manifest")
        target = destination / normalized
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
        source = archive.extractfile(member)
        if source is None:
            raise SystemExit("archive member has no readable payload")
        descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with source, os.fdopen(descriptor, "wb") as output:
            shutil.copyfileobj(source, output)
        os.chmod(target, 0o644)
        seen_files.add(normalized)

if seen_files != set(expected):
    raise SystemExit("archive and manifest file sets differ")

for path, entry in expected.items():
    target = destination / path
    if not target.is_file() or target.is_symlink():
        raise SystemExit("extracted path is not a regular file")
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    if target.stat().st_size != entry["size"] or digest != entry["sha256"]:
        raise SystemExit("extracted file does not match the manifest")
PYTHON

install -o root -g nginx -m 0440 "$manifest_path" "$extracted_path/.platform-manifest.json"
chown -R root:nginx "$extracted_path"
find "$extracted_path" -type d -exec chmod 0550 {} +
find "$extracted_path" -type f -exec chmod 0440 {} +
mv -- "$extracted_path" "$release_dir"

next_link="${current_link}.next.$$"
ln -s "$release_dir" "$next_link"
mv -Tf "$next_link" "$current_link"
activated=1

nginx -t
systemctl reload nginx.service
/usr/local/lib/platform/smoke-portfolio.sh http://127.0.0.1 "$current_link"

state_file="$state_root/current-release.json"
state_temporary="${state_file}.next.$$"
printf '{"releaseId":"%s","artifactSha256":"%s","activatedAt":"%s"}\n' \
  "$release_id" "$artifact_sha256" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >"$state_temporary"
chown root:nginx "$state_temporary"
chmod 0440 "$state_temporary"
mv -f -- "$state_temporary" "$state_file"

declare -A retained=()
retained["$release_dir"]=1
if [[ -n "$previous_target" ]] && [[ "$previous_target" == "$releases_root"/* ]]; then
  retained["$previous_target"]=1
fi

additional=0
while IFS='|' read -r _candidate_time candidate; do
  [[ -n "$candidate" ]] || continue
  if [[ -n "${retained[$candidate]:-}" ]]; then
    continue
  fi
  if ((additional < 3)); then
    retained["$candidate"]=1
    additional=$((additional + 1))
    continue
  fi
  [[ "$candidate" == "$releases_root"/* ]]
  rm -rf -- "$candidate"
done < <(find "$releases_root" -mindepth 1 -maxdepth 1 -type d -printf '%T@|%p\n' | sort -t '|' -k1,1nr)

printf 'deployment %s completed at %s\n' "$release_id" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
