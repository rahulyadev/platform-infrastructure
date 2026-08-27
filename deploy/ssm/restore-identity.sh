#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
set +x

readonly recovery_target="${SSM_recoveryTarget:-immediate}"
metadata_root=/var/lib/platform/identity-recovery
selector_only=false
if [[ "${1:-}" == --metadata-fixture ]]; then
  [[ $# == 1 ]]
  metadata_root="${PLATFORM_IDENTITY_RECOVERY_METADATA_ROOT:?fixture metadata root required}"
  [[ "$metadata_root" == /tmp/* && -d "$metadata_root" && ! -L "$metadata_root" ]]
  [[ "$metadata_root" == "$(realpath -e -- "$metadata_root")" ]]
  selector_only=true
else
  [[ $# == 0 ]]
fi
[[ "$recovery_target" == immediate || "$recovery_target" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]

readonly selection="$(mktemp)"
chmod 0600 "$selection"
select_cleanup() { rm -f -- "$selection"; }
trap select_cleanup EXIT

python3 - "$metadata_root" "$recovery_target" "$selection" <<'PY'
import datetime
import json
import pathlib
import re
import sys
root = pathlib.Path(sys.argv[1])
target_text = sys.argv[2]
destination = pathlib.Path(sys.argv[3])
required = {"version", "marker", "marker_created_at", "backup_label", "backup_type", "backup_started_at", "backup_stopped_at", "schema_head"}
def timestamp(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value):
        raise ValueError
    return datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
records = []
for path in sorted(root.glob("identity-backup-*.json")):
    if path.is_symlink() or not path.is_file() or path.stat().st_mode & 0o077:
        raise SystemExit(2)
    value = json.loads(path.read_text(encoding="ascii"))
    if not isinstance(value, dict) or set(value) != required or value["version"] != 1:
        raise SystemExit(2)
    if not isinstance(value["marker"], str) or not re.fullmatch(r"[0-9a-f]{32}", value["marker"]):
        raise SystemExit(2)
    if not isinstance(value["backup_label"], str) or not re.fullmatch(r"[0-9]{8}-[0-9]{6}F(?:_[0-9]{8}-[0-9]{6}[DIF])?", value["backup_label"]):
        raise SystemExit(2)
    if value["backup_type"] not in {"full", "diff", "incr"} or value["schema_head"] != "0001_initial_identity_schema":
        raise SystemExit(2)
    created = timestamp(value["marker_created_at"])
    started = timestamp(value["backup_started_at"])
    stopped = timestamp(value["backup_stopped_at"])
    if created > started or started > stopped:
        raise SystemExit(2)
    records.append((stopped, created, value))
if not records:
    raise SystemExit(3)
if target_text == "immediate":
    eligible = records
else:
    target = timestamp(target_text)
    eligible = [record for record in records if record[0] <= target and record[1] <= target]
if not eligible:
    raise SystemExit(3)
selected = max(eligible, key=lambda record: (record[0], record[1]))[2]
destination.write_text(json.dumps(selected, sort_keys=True, separators=(",", ":")) + "\n", encoding="ascii")
PY

if [[ "$selector_only" == true ]]; then
  printf 'Identity recovery metadata selection passed.\n'
  exit 0
fi

readonly lifecycle_lock=/run/lock/platform-identity-lifecycle.lock
install -d -m 0755 /run/lock
exec 9>"$lifecycle_lock"
flock -w 30 9
readonly restore_root="$(mktemp -d /var/lib/platform/identity-restore-rehearsal.XXXXXXXX)"
readonly container="identity-restore-${RANDOM}${RANDOM}"
readonly compose_file=/opt/platform/identity/current/compose.yml
chmod 0700 "$restore_root"
chown 999:65532 "$restore_root"
chmod 0750 "$restore_root"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  chmod -R u+rwx "$restore_root" >/dev/null 2>&1 || true
  rm -rf -- "$restore_root"
  rm -f -- "$selection"
}
trap cleanup EXIT

/usr/local/libexec/platform/identity-verify-release
set -a
source /etc/platform/identity/release.env
set +a
postgres_image="$(docker compose --file "$compose_file" --project-name identity-production config --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["postgres"]["image"])')"
[[ "$postgres_image" =~ ^postgres@sha256:[0-9a-f]{64}$ ]]

readarray -t recovery < <(python3 - "$selection" <<'PY'
import json
import pathlib
import sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="ascii"))
for key in ("marker", "marker_created_at", "backup_label"):
    print(value[key])
PY
)
[[ "${#recovery[@]}" == 3 ]]
readonly expected_marker="${recovery[0]}"
readonly expected_marker_created_at="${recovery[1]}"
readonly backup_label="${recovery[2]}"

restore_arguments=(--stanza=identity --pg1-path=/restore/data --set="$backup_label")
if [[ "$recovery_target" == immediate ]]; then
  restore_arguments+=(restore)
else
  restore_arguments+=(--type=time --target="$recovery_target" --target-action=promote restore)
fi
docker compose --file "$compose_file" --project-name identity-production run --rm --no-deps \
  --volume "$restore_root:/restore" --entrypoint pgbackrest pgbackrest "${restore_arguments[@]}"
test -f "$restore_root/data/PG_VERSION"
docker run --rm --user 0:0 --volume "$restore_root/data:/restore" --entrypoint /bin/sh "$postgres_image" \
  -c 'chown -R 999:999 /restore && chmod 0700 /restore'
docker run --detach --name "$container" --network none --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev --tmpfs /run/postgresql:rw,nosuid,nodev \
  --volume "$restore_root/data:/var/lib/postgresql/18/docker" "$postgres_image" postgres \
  -c listen_addresses= -c archive_mode=off >/dev/null
for _ in {1..60}; do
  if docker exec "$container" pg_isready --dbname identity --username identity_bootstrap >/dev/null 2>&1; then break; fi
  sleep 1
done
docker exec "$container" pg_isready --dbname identity --username identity_bootstrap >/dev/null

proof="$(docker exec --interactive "$container" psql --username identity_bootstrap --dbname identity --no-psqlrc --tuples-only --no-align \
  --set marker="$expected_marker" --set marker_created_at="$expected_marker_created_at" --set recovery_target="$recovery_target" <<'SQL'
SELECT concat_ws(':',
  (SELECT version_num = '0001_initial_identity_schema' FROM identity.alembic_version),
  EXISTS (SELECT 1 FROM platform_recovery.markers WHERE marker = :'marker' AND created_at = :'marker_created_at'::timestamptz),
  NOT has_schema_privilege('identity_service_app', 'platform_recovery', 'USAGE'),
  NOT has_table_privilege('identity_service_app', 'platform_recovery.markers', 'SELECT'),
  CASE WHEN :'recovery_target' = 'immediate' THEN true
       ELSE NOT EXISTS (SELECT 1 FROM platform_recovery.markers WHERE created_at > :'recovery_target'::timestamptz)
  END
);
SQL
)"
[[ "$proof" == t:t:t:t:t ]]
writable="$(docker exec "$container" psql --username identity_bootstrap --dbname identity --no-psqlrc --tuples-only --no-align \
  --command "BEGIN; CREATE TEMP TABLE restore_writability(value text); INSERT INTO restore_writability VALUES ('ok'); SELECT value FROM restore_writability; ROLLBACK;")"
[[ "$writable" == ok ]]
printf 'Identity isolated restore rehearsal proved the exact migration head and pre-backup recovery marker.\n'
