#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
set +x

readonly recovery_target="${SSM_recoveryTarget:-immediate}"
readonly restore_root="$(mktemp -d /var/lib/platform/identity-restore-rehearsal.XXXXXXXX)"
readonly container="identity-restore-${RANDOM}${RANDOM}"
readonly compose_file=/opt/platform/identity/current/compose.yml
[[ "$recovery_target" == immediate || "$recovery_target" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
chmod 0700 "$restore_root"
chown 999:65532 "$restore_root"
chmod 0750 "$restore_root"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  chmod -R u+rwx "$restore_root" >/dev/null 2>&1 || true
  rm -rf -- "$restore_root"
}
trap cleanup EXIT

set -a
/usr/local/libexec/platform/identity-verify-release
source /etc/platform/identity/release.env
set +a
postgres_image="$(docker compose --file "$compose_file" --project-name identity-production config --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["postgres"]["image"])')"
[[ "$postgres_image" =~ ^postgres@sha256:[0-9a-f]{64}$ ]]

restore_arguments=(--stanza=identity --pg1-path=/restore/data)
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
  if docker exec "$container" pg_isready --dbname identity --username identity_bootstrap >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
observed_head="$(docker exec "$container" psql --username identity_bootstrap --dbname identity --no-psqlrc --tuples-only --no-align \
  --command 'SELECT version_num FROM identity.alembic_version;')"
[[ "$observed_head" == 0001_initial_identity_schema ]]
sentinel="$(docker exec "$container" psql --username identity_bootstrap --dbname identity --no-psqlrc --tuples-only --no-align \
  --command "BEGIN; CREATE TEMP TABLE restore_sentinel(value text); INSERT INTO restore_sentinel VALUES ('restore-rehearsal-ok'); SELECT value FROM restore_sentinel; ROLLBACK;")"
[[ "$sentinel" == restore-rehearsal-ok ]]
printf 'Identity isolated restore rehearsal proved the exact migration head and sentinel row.\n'
