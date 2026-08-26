#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
set +x

readonly current=/opt/platform/identity/current
readonly previous=/opt/platform/identity/previous
[[ -L "$previous" ]]
rollback_target="$(readlink -f -- "$previous")"
[[ -f "$rollback_target/compose.yml" && -f "$rollback_target/release.env" ]]
target_schema="$(sed -n 's/^IDENTITY_SCHEMA_HEAD=//p' "$rollback_target/release.env")"
[[ "$target_schema" == 0001_initial_identity_schema ]]
/usr/local/libexec/platform/identity-verify-release
set -a
source /etc/platform/identity/release.env
set +a
live_schema="$(docker compose --file "$current/compose.yml" --project-name identity-production exec --no-TTY \
  --env PGPASSFILE=/run/secrets/database/bootstrap.pgpass postgres \
  psql 'host=postgres port=5432 dbname=identity user=identity_bootstrap sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt' \
  --no-psqlrc --tuples-only --no-align --command 'SELECT version_num FROM identity.alembic_version;')"
[[ "$live_schema" == "$target_schema" ]]
current_target="$(readlink -f -- "$current")"
ln -s -- "$rollback_target" "$current.next"
mv -Tf -- "$current.next" "$current"
install -m 0600 "$rollback_target/release.env" /etc/platform/identity/release.env
systemctl restart identity-stack.service
/usr/local/libexec/platform/identity-health-verify
ln -s -- "$current_target" "$previous.next"
mv -Tf -- "$previous.next" "$previous"
printf 'Identity rollback restored a migration-compatible retained release.\n'
