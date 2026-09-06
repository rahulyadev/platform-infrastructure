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
readonly archive_container="${container}-archive"
readonly restore_network="${container}-network"
readonly compose_file=/opt/platform/identity/current/compose.yml
readonly release_environment=/etc/platform/identity/release.env
readonly -a compose=(docker compose --env-file "$release_environment" --file "$compose_file" --project-name identity-production)
chmod 0700 "$restore_root"
chown 999:65532 "$restore_root"
chmod 0750 "$restore_root"
restore_stage=release_validation

cleanup() {
  local status=$?
  local diagnostic_role diagnostic_container diagnostic_log running exit_code log_bytes log_lines log_sha error_count normalized_proof
  trap - EXIT
  set +e
  if ((status != 0)); then
    printf 'RESTORE_FAILURE_STAGE=%s\nRESTORE_FAILURE_STATUS=%s\n' "$restore_stage" "$status"
    if [[ -n "${proof:-}" ]]; then
      normalized_proof="$(printf '%s' "$proof" | tr -d '[:space:]')"
      printf 'RESTORE_FAILURE_PROOF_BYTES=%s\nRESTORE_FAILURE_PROOF_SHA256=%s\n' \
        "$(printf '%s' "$proof" | wc -c | tr -d ' ')" "$(printf '%s' "$proof" | sha256sum | cut -d' ' -f1)"
      if [[ "$normalized_proof" =~ ^[tf](:[tf]){0,4}$ ]]; then
        printf 'RESTORE_FAILURE_PROOF=%s\n' "$normalized_proof"
      fi
    fi
    for diagnostic_role in archive postgres; do
      if [[ "$diagnostic_role" == archive ]]; then
        diagnostic_container="$archive_container"
      else
        diagnostic_container="$container"
      fi
      if docker inspect "$diagnostic_container" >/dev/null 2>&1; then
        diagnostic_log="$restore_root/$diagnostic_role.log"
        docker logs "$diagnostic_container" >"$diagnostic_log" 2>&1
        running="$(docker inspect --format '{{.State.Running}}' "$diagnostic_container")"
        exit_code="$(docker inspect --format '{{.State.ExitCode}}' "$diagnostic_container")"
        log_bytes="$(wc -c <"$diagnostic_log" | tr -d ' ')"
        log_lines="$(wc -l <"$diagnostic_log" | tr -d ' ')"
        log_sha="$(sha256sum "$diagnostic_log" | cut -d' ' -f1)"
        error_count="$(grep -Eic 'error|fatal|permission denied|not found|command not found' "$diagnostic_log" || true)"
        printf 'RESTORE_FAILURE_%s_RUNNING=%s\nRESTORE_FAILURE_%s_EXIT_CODE=%s\nRESTORE_FAILURE_%s_LOG_BYTES=%s\nRESTORE_FAILURE_%s_LOG_LINES=%s\nRESTORE_FAILURE_%s_LOG_SHA256=%s\nRESTORE_FAILURE_%s_ERROR_COUNT=%s\n' \
          "${diagnostic_role^^}" "$running" "${diagnostic_role^^}" "$exit_code" \
          "${diagnostic_role^^}" "$log_bytes" "${diagnostic_role^^}" "$log_lines" \
          "${diagnostic_role^^}" "$log_sha" "${diagnostic_role^^}" "$error_count"
      fi
    done
  fi
  docker rm -f "$archive_container" >/dev/null 2>&1 || true
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker network rm "$restore_network" >/dev/null 2>&1 || true
  chmod -R u+rwx "$restore_root" >/dev/null 2>&1 || true
  rm -rf -- "$restore_root"
  rm -f -- "$selection"
  exit "$status"
}
trap cleanup EXIT

/usr/local/libexec/platform/identity-verify-release
restore_stage=image_validation
readarray -t restore_images < <("${compose[@]}" config --format json | python3 -c '
import json,sys
services=json.load(sys.stdin)["services"]
print(services["postgres"]["image"])
print(services["pgbackrest"]["image"])
')
[[ "${#restore_images[@]}" == 2 ]]
postgres_image="${restore_images[0]}"
pgbackrest_image="${restore_images[1]}"
[[ "$postgres_image" =~ ^postgres@sha256:[0-9a-f]{64}$ ]]
[[ "$pgbackrest_image" =~ ^woblerr/pgbackrest@sha256:[0-9a-f]{64}$ ]]
[[ -f /etc/platform/identity/secrets/database/bootstrap.pgpass && ! -L /etc/platform/identity/secrets/database/bootstrap.pgpass ]]
[[ "$(stat -c '%a:%u:%g' /etc/platform/identity/secrets/database/bootstrap.pgpass)" == 600:10001:10001 ]]
[[ -f /etc/platform/identity/tls/postgres-client/ca.crt && ! -L /etc/platform/identity/tls/postgres-client/ca.crt ]]
[[ "$(stat -c '%a:%u:%g' /etc/platform/identity/tls/postgres-client/ca.crt)" == 440:0:10001 ]]

run_restore_psql() {
  docker run --rm --interactive --network "$restore_network" --user 10001:10001 --read-only --cap-drop ALL \
    --security-opt no-new-privileges --pids-limit 64 --tmpfs /tmp:rw,noexec,nosuid,nodev,size=32m \
    --mount type=bind,src=/etc/platform/identity/secrets/database/bootstrap.pgpass,dst=/run/secrets/database/bootstrap.pgpass,readonly \
    --mount type=bind,src=/etc/platform/identity/tls/postgres-client/ca.crt,dst=/run/tls/postgres/ca.crt,readonly \
    --env PGPASSFILE=/run/secrets/database/bootstrap.pgpass --entrypoint psql "$postgres_image" \
    'host=postgres port=5432 dbname=identity user=identity_bootstrap sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt' \
    --no-psqlrc --set ON_ERROR_STOP=1 "$@"
}

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
restore_stage=backup_restore
"${compose[@]}" run --rm --no-deps \
  --volume "$restore_root:/restore" --entrypoint /opt/platform/pgbackrest-sidecar pgbackrest "${restore_arguments[@]}"
test -f "$restore_root/data/PG_VERSION"
docker run --rm --user 0:0 --volume "$restore_root/data:/restore" --entrypoint /bin/sh "$postgres_image" \
  -c 'chown -R 999:999 /restore && chmod 0700 /restore'
archive_root="$restore_root/archive"
install -d -o 0 -g 0 -m 0755 "$archive_root"
install -d -o 999 -g 999 -m 0700 "$archive_root/requests" "$archive_root/results" "$archive_root/missing"
cat >"$archive_root/archive-fetcher" <<'FETCHER'
#!/bin/sh
set -eu
umask 077
while [ ! -f /archive/stop ]; do
  found=false
  for request in /archive/requests/*; do
    [ -f "$request" ] || continue
    found=true
    name="${request##*/}"
    if ! printf '%s\n' "$name" | grep -Eq '^([0-9A-F]{24}|[0-9A-F]{8}[.]history)([.]partial)?$'; then
      exit 2
    fi
    result="/archive/results/$name"
    missing="/archive/missing/$name"
    if [ ! -f "$result" ] && [ ! -f "$missing" ]; then
      if /opt/platform/pgbackrest-sidecar --stanza=identity --no-archive-async archive-get "$name" "$result.next"; then
        chmod 0400 "$result.next"
        mv -f -- "$result.next" "$result"
      else
        rm -f -- "$result.next"
        : >"$missing"
      fi
    fi
    rm -f -- "$request"
  done
  [ "$found" = true ] || sleep 1
done
FETCHER
cat >"$archive_root/restore-command" <<'RESTORE_COMMAND'
#!/bin/sh
set -eu
umask 077
[ "$#" -eq 2 ]
name="$1"
destination="$2"
printf '%s\n' "$name" | grep -Eq '^([0-9A-F]{24}|[0-9A-F]{8}[.]history)([.]partial)?$'
case "$destination" in /*) ;; *) exit 2 ;; esac
result="/archive/results/$name"
missing="/archive/missing/$name"
if [ ! -f "$result" ] && [ ! -f "$missing" ]; then
  request="/archive/requests/$name"
  request_next="/archive/requests/.$name.next"
  : >"$request_next"
  mv -f -- "$request_next" "$request"
fi
for _ in $(seq 1 120); do
  if [ -f "$result" ]; then
    cp -- "$result" "$destination"
    chmod 0600 "$destination"
    exit 0
  fi
  [ ! -f "$missing" ] || exit 1
  sleep 1
done
exit 1
RESTORE_COMMAND
chmod 0555 "$archive_root/archive-fetcher" "$archive_root/restore-command"
restore_stage=archive_fetcher
docker run --detach --name "$archive_container" --network host --user 999:65532 --read-only \
  --cap-drop ALL --security-opt no-new-privileges --pids-limit 64 \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=32m \
  --env PGBACKREST_CONFIG=/etc/pgbackrest.conf \
  --mount type=bind,src=/etc/platform/identity/pgbackrest.conf,dst=/etc/pgbackrest.conf,readonly \
  --mount type=bind,src=/etc/platform/identity/secrets/backup,dst=/run/secrets/backup,readonly \
  --mount type=bind,src=/usr/local/libexec/platform/pgbackrest-sidecar,dst=/opt/platform/pgbackrest-sidecar,readonly \
  --mount type=bind,src=/etc/platform/identity/pgbackrest-passwd,dst=/etc/passwd,readonly \
  --mount type=bind,src="$restore_root/data",dst=/var/lib/postgresql/18/docker,readonly \
  --mount type=bind,src="$archive_root",dst=/archive \
  --entrypoint /bin/sh "$pgbackrest_image" /archive/archive-fetcher >/dev/null
[[ "$(docker inspect --format '{{.State.Running}}' "$archive_container")" == true ]]
restore_stage=postgres_readiness
docker network create --internal "$restore_network" >/dev/null
docker run --detach --name "$container" --network "$restore_network" --network-alias postgres \
  --user 999:999 --read-only --cap-drop ALL --security-opt no-new-privileges \
  --tmpfs /tmp:rw,noexec,nosuid,nodev --tmpfs /run/postgresql:rw,nosuid,nodev \
  --volume "$restore_root/data:/var/lib/postgresql/18/docker" \
  --mount type=bind,src="$archive_root",dst=/archive \
  --mount type=bind,src=/etc/platform/identity/tls/postgres-server,dst=/run/tls/postgres,readonly \
  --mount type=bind,src=/etc/platform/identity/postgres-hba.conf,dst=/run/config/postgres-hba.conf,readonly \
  "$postgres_image" postgres -c listen_addresses='*' -c archive_mode=off -c ssl=on \
  -c 'restore_command=/archive/restore-command %f /var/lib/postgresql/18/docker/%p' \
  -c ssl_cert_file=/run/tls/postgres/server.crt -c ssl_key_file=/run/tls/postgres/server.key \
  -c ssl_ca_file=/run/tls/postgres/ca.crt -c hba_file=/run/config/postgres-hba.conf >/dev/null
for _ in {1..300}; do
  if run_restore_psql --tuples-only --no-align --command 'SELECT 1;' >/dev/null 2>&1; then break; fi
  sleep 1
done
[[ "$(run_restore_psql --tuples-only --no-align --command 'SELECT 1;')" == 1 ]]

restore_stage=recovery_proof_query
proof="$(run_restore_psql --tuples-only --no-align \
  --set marker="$expected_marker" --set marker_created_at="$expected_marker_created_at" --set recovery_target="$recovery_target" <<'SQL'
SELECT concat_ws(':',
  (SELECT count(*) = 1 AND min(version_num) = '0001_initial_identity_schema' FROM identity.alembic_version),
  EXISTS (SELECT 1 FROM platform_recovery.markers WHERE marker = :'marker' AND created_at = :'marker_created_at'::timestamptz),
  NOT has_schema_privilege('identity_service_app', 'platform_recovery', 'USAGE'),
  NOT has_table_privilege('identity_service_app', 'platform_recovery.markers', 'SELECT'),
  CASE WHEN :'recovery_target' = 'immediate' THEN true
       ELSE NOT EXISTS (SELECT 1 FROM platform_recovery.markers WHERE created_at > NULLIF(:'recovery_target', 'immediate')::timestamptz)
  END
);
SQL
)"
restore_stage=recovery_proof_assertion
[[ "$proof" == t:t:t:t:t ]]
restore_stage=recovery_writability
writable="$(run_restore_psql --quiet --tuples-only --no-align \
  --command "BEGIN; CREATE TEMP TABLE restore_writability(value text); INSERT INTO restore_writability VALUES ('ok'); SELECT value FROM restore_writability; ROLLBACK;")"
restore_stage=recovery_writability_assertion
[[ "$writable" == ok ]]
printf 'Identity isolated restore rehearsal proved the exact migration head and pre-backup recovery marker.\n'
