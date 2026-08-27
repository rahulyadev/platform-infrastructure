#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
set +x

test_root="${PLATFORM_IDENTITY_LIFECYCLE_TEST_ROOT:-}"
if [[ -n "$test_root" ]]; then
  [[ "${1:-}" == --activation-fixture ]]
  [[ "$test_root" == /tmp/* && -d "$test_root" && ! -L "$test_root" ]]
  [[ "$test_root" == "$(realpath -e -- "$test_root")" ]]
else
  [[ $# == 0 ]]
fi
rooted() { printf '%s%s\n' "$test_root" "$1"; }

readonly lifecycle_lock="$(rooted /run/lock/platform-identity-lifecycle.lock)"
install -d -m 0755 "$(dirname -- "$lifecycle_lock")"
exec 9>"$lifecycle_lock"
flock -w 30 9

readonly releases="$(rooted /opt/platform/identity/releases)"
readonly current="$(rooted /opt/platform/identity/current)"
readonly previous="$(rooted /opt/platform/identity/previous)"
readonly release_environment="$(rooted /etc/platform/identity/release.env)"
readonly nginx_configuration="$(rooted /etc/nginx/conf.d/identity-runtime.conf)"
readonly verify_release="$(rooted /usr/local/libexec/platform/identity-verify-release)"
readonly health_verify="$(rooted /usr/local/libexec/platform/identity-health-verify)"
activation_started=false
activation_committed=false
prior_service_active=false
transaction=""

inject_failure() {
  if [[ -n "$test_root" && "${PLATFORM_IDENTITY_FAIL_AT:-}" == "$1" ]]; then
    return 97
  fi
}

atomic_file() {
  local source="$1" target="$2" mode="$3" temporary
  temporary="$(dirname -- "$target")/.$(basename -- "$target").identity.$$.next"
  rm -f -- "$temporary"
  install -m "$mode" "$source" "$temporary"
  mv -Tf -- "$temporary" "$target"
}

atomic_link() {
  local target="$1" link="$2" temporary
  temporary="$(dirname -- "$link")/.$(basename -- "$link").identity.$$.next"
  rm -f -- "$temporary"
  ln -s -- "$target" "$temporary"
  mv -Tf -- "$temporary" "$link"
}

capture_link() {
  local link="$1" label="$2"
  if [[ -L "$link" ]]; then
    readlink -- "$link" >"$transaction/$label.link"
  elif [[ -e "$link" ]]; then
    return 1
  else
    : >"$transaction/$label.absent"
  fi
}

capture_file() {
  local target="$1" label="$2"
  if [[ -e "$target" || -L "$target" ]]; then
    [[ -f "$target" && ! -L "$target" ]]
    cp --archive -- "$target" "$transaction/$label.file"
  else
    : >"$transaction/$label.absent"
  fi
}

restore_link() {
  local link="$1" label="$2"
  if [[ -f "$transaction/$label.link" ]]; then
    atomic_link "$(<"$transaction/$label.link")" "$link"
  else
    rm -f -- "$link"
  fi
}

restore_file() {
  local target="$1" label="$2" mode="$3"
  if [[ -f "$transaction/$label.file" ]]; then
    atomic_file "$transaction/$label.file" "$target" "$mode"
  else
    rm -f -- "$target"
  fi
}

restore_original() {
  local status=0
  set +e
  restore_link "$current" current || status=1
  restore_link "$previous" previous || status=1
  restore_file "$release_environment" environment 0600 || status=1
  restore_file "$nginx_configuration" nginx 0644 || status=1
  nginx -t >/dev/null 2>&1 || status=1
  systemctl reload nginx >/dev/null 2>&1 || status=1
  if [[ "$prior_service_active" == true ]]; then
    systemctl restart identity-stack.service >/dev/null 2>&1 || status=1
    "$verify_release" >/dev/null 2>&1 || status=1
    "$health_verify" >/dev/null 2>&1 || status=1
  else
    systemctl stop identity-stack.service >/dev/null 2>&1 || status=1
  fi
  find "$(dirname -- "$current")" "$(dirname -- "$release_environment")" "$(dirname -- "$nginx_configuration")" \
    -maxdepth 1 -type f -name '*.identity.*.next' -delete >/dev/null 2>&1 || status=1
  set -e
  return "$status"
}

on_error() {
  local original_status=$?
  trap - ERR
  if [[ "$activation_started" == true && "$activation_committed" == false ]]; then
    if ! restore_original; then
      printf 'Identity rollback failed and original health restoration failed.\n' >&2
      exit 1
    fi
  fi
  printf 'Identity rollback failed; the original healthy release was restored.\n' >&2
  exit "$original_status"
}
trap on_error ERR
trap '[[ -z "$transaction" || ! -d "$transaction" ]] || rm -rf -- "$transaction"' EXIT

[[ -L "$current" && -L "$previous" ]]
original_target="$(readlink -f -- "$current")"
rollback_target="$(readlink -f -- "$previous")"
[[ "$original_target" == "$releases"/* && "$rollback_target" == "$releases"/* ]]
[[ "$original_target" != "$rollback_target" ]]
[[ -x "$verify_release" && -x "$health_verify" ]]
"$verify_release" "$rollback_target"
"$verify_release" "$original_target"
"$health_verify"

target_schema="$(sed -n 's/^IDENTITY_SCHEMA_HEAD=//p' "$rollback_target/release.env")"
[[ "$target_schema" == 0001_initial_identity_schema ]]
if [[ -z "$test_root" ]]; then
  live_schema="$(docker compose --file "$original_target/compose.yml" --project-name identity-production exec --no-TTY \
    --env PGPASSFILE=/run/secrets/database/bootstrap.pgpass postgres \
    psql 'host=postgres port=5432 dbname=identity user=identity_bootstrap sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt' \
    --no-psqlrc --tuples-only --no-align --command 'SELECT version_num FROM identity.alembic_version;')"
else
  live_schema="${PLATFORM_IDENTITY_FIXTURE_SCHEMA:?fixture schema required}"
fi
[[ "$live_schema" == "$target_schema" ]]

transaction="$(mktemp -d "$(rooted /run)/platform-identity-rollback.XXXXXXXX")"
chmod 0700 "$transaction"
capture_link "$current" current
capture_link "$previous" previous
capture_file "$release_environment" environment
capture_file "$nginx_configuration" nginx
if systemctl is-active --quiet identity-stack.service; then
  prior_service_active=true
fi

activation_started=true
atomic_link "$rollback_target" "$current"
inject_failure current_link
atomic_file "$rollback_target/release.env" "$release_environment" 0600
inject_failure release_environment
nginx -t
inject_failure nginx_validation
systemctl reload nginx
inject_failure nginx_reload
systemctl restart identity-stack.service
inject_failure service_restart
"$verify_release" "$rollback_target"
inject_failure release_verification
"$health_verify"
inject_failure health_verification
atomic_link "$original_target" "$previous"
inject_failure previous_promotion
activation_committed=true
rm -rf -- "$transaction"
transaction=""
printf 'Identity rollback restored a migration-compatible retained release.\n'
