#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
set +x

test_root="${PLATFORM_IDENTITY_LIFECYCLE_TEST_ROOT:-}"
if [[ -n "$test_root" ]]; then
  [[ "${1:-}" == --activation-fixture || "${1:-}" == --cleanup-fixture ]]
  [[ "$test_root" == /tmp/* && -d "$test_root" && ! -L "$test_root" ]]
  [[ "$test_root" == "$(realpath -e -- "$test_root")" ]]
else
  [[ $# == 0 ]]
fi

rooted() {
  printf '%s%s\n' "$test_root" "$1"
}

readonly lifecycle_lock="$(rooted /run/lock/platform-identity-lifecycle.lock)"
install -d -m 0755 "$(dirname -- "$lifecycle_lock")"
exec 9>"$lifecycle_lock"
flock -w 30 9

readonly releases="$(rooted /opt/platform/identity/releases)"
readonly current="$(rooted /opt/platform/identity/current)"
readonly previous="$(rooted /opt/platform/identity/previous)"
readonly generation="$(rooted /etc/platform/identity)"
readonly release_environment="$(rooted /etc/platform/identity/release.env)"
readonly nginx_configuration="$(rooted /etc/nginx/conf.d/identity-runtime.conf)"
readonly verify_release="$(rooted /usr/local/libexec/platform/identity-verify-release)"
readonly health_verify="$(rooted /usr/local/libexec/platform/identity-health-verify)"
readonly api_repository='__IDENTITY_API_REPOSITORY_URL__'
readonly bff_repository='__IDENTITY_BFF_REPOSITORY_URL__'
readonly ecr_registry='__IDENTITY_ECR_REGISTRY__'
readonly schema_head=0001_initial_identity_schema
activation_started=false
activation_committed=false
transaction=""
prior_service_active=false
recovery_info=""
recovery_metadata=""
release=""
release_created=false
preactivation_services_started=false

inject_failure() {
  if [[ -n "$test_root" && "${PLATFORM_IDENTITY_FAIL_AT:-}" == "$1" ]]; then
    return 97
  fi
}

atomic_file() {
  local source="$1" target="$2" mode="$3" temporary
  install -d -m 0755 "$(dirname -- "$target")"
  temporary="$(dirname -- "$target")/.$(basename -- "$target").identity.$$.next"
  rm -f -- "$temporary"
  install -m "$mode" "$source" "$temporary"
  mv -Tf -- "$temporary" "$target"
}

atomic_link() {
  local target="$1" link="$2" temporary
  install -d -m 0755 "$(dirname -- "$link")"
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
  rm -f -- "$(dirname -- "$link")/.$(basename -- "$link").identity.$$.next"
  if [[ -f "$transaction/$label.link" ]]; then
    atomic_link "$(<"$transaction/$label.link")" "$link"
  else
    rm -f -- "$link"
  fi
}

restore_file() {
  local target="$1" label="$2" mode="$3"
  rm -f -- "$(dirname -- "$target")/.$(basename -- "$target").identity.$$.next"
  if [[ -f "$transaction/$label.file" ]]; then
    atomic_file "$transaction/$label.file" "$target" "$mode"
  else
    rm -f -- "$target"
  fi
}

deployment_failed_metric() {
  [[ -z "$test_root" ]] || return 0
  local metadata_token instance_id
  metadata_token="$(curl --fail --silent --max-time 3 --request PUT --header 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token 2>/dev/null || true)"
  instance_id="$(curl --fail --silent --max-time 3 --header "X-aws-ec2-metadata-token: $metadata_token" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || true)"
  [[ -n "$instance_id" ]] || return 0
  aws cloudwatch put-metric-data --region ap-south-1 --namespace PlatformInfrastructure/Production/Identity \
    --metric-data "MetricName=IdentityDeploymentFailure,Dimensions=[{Name=InstanceId,Value=$instance_id}],Value=1,Unit=Count" >/dev/null 2>&1 || true
}

restore_prior_release() {
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
  rm -f -- "$(dirname -- "$current")/.current.identity.$$.next" \
    "$(dirname -- "$previous")/.previous.identity.$$.next" \
    "$(dirname -- "$release_environment")/.release.env.identity.$$.next" \
    "$(dirname -- "$nginx_configuration")/.identity-runtime.conf.identity.$$.next"
  set -e
  return "$status"
}

remove_unactivated_release() {
  local link name expected_owner=0:0
  [[ -z "$test_root" ]] || expected_owner="$(id -u):$(id -g)"
  [[ "$release_created" == true && -n "$release" ]] || return 0
  [[ "$release" == "$releases"/* && -d "$release" && ! -L "$release" ]] || return
  for link in "$current" "$previous"; do
    if [[ -L "$link" ]]; then
      [[ "$(readlink -f -- "$link")" != "$release" ]] || return
    else
      [[ ! -e "$link" ]] || return
    fi
  done
  [[ -z "$(find "$release" -mindepth 1 -maxdepth 1 ! -name compose.yml ! -name release.env -print -quit)" ]] || return
  for name in compose.yml release.env; do
    if [[ -e "$release/$name" || -L "$release/$name" ]]; then
      [[ -f "$release/$name" && ! -L "$release/$name" && "$(stat -c '%u:%g' "$release/$name")" == "$expected_owner" ]] || return
      if [[ "$name" == compose.yml ]]; then [[ "$(stat -c '%a' "$release/$name")" == 644 ]] || return; else [[ "$(stat -c '%a' "$release/$name")" == 600 ]] || return; fi
      rm -- "$release/$name" || return
    fi
  done
  rmdir -- "$release" || return
  [[ ! -e "$release" && ! -L "$release" ]] || return
  release_created=false
}

stop_preactivation_services() {
  [[ "$preactivation_services_started" == true ]] || return 0
  [[ "$release" == "$releases"/* && -d "$release" && ! -L "$release" ]] || return
  [[ -f "$release/compose.yml" && ! -L "$release/compose.yml" ]] || return
  [[ -f "$release/release.env" && ! -L "$release/release.env" ]] || return
  docker compose --file "$release/compose.yml" --project-name identity-production down --remove-orphans || return
  [[ -z "$(docker ps --all --filter label=com.docker.compose.project=identity-production --format '{{.ID}}')" ]] || return
  preactivation_services_started=false
}

on_error() {
  local original_status=$? recovery_status=0
  trap - ERR
  deployment_failed_metric
  if [[ "$activation_started" == true && "$activation_committed" == false ]]; then
    restore_prior_release || recovery_status=1
  elif [[ "$activation_started" == false ]]; then
    stop_preactivation_services || recovery_status=1
  fi
  if [[ "$recovery_status" == 0 ]]; then
    remove_unactivated_release || recovery_status=1
  fi
  if [[ "$recovery_status" != 0 ]]; then
    printf 'Identity deployment failed and exact prior-state recovery failed.\n' >&2
    exit 1
  fi
  printf 'Identity deployment failed; the prior healthy release was restored.\n' >&2
  exit "$original_status"
}
trap on_error ERR

activate_release() {
  local release="$1" old_target=""
  [[ "$release" == "$releases"/* && -d "$release" && ! -L "$release" ]]
  [[ -x "$verify_release" && -x "$health_verify" ]]
  "$verify_release" "$release"

  transaction="$(mktemp -d "$(rooted /run)/platform-identity-activation.XXXXXXXX")"
  chmod 0700 "$transaction"
  capture_link "$current" current
  capture_link "$previous" previous
  capture_file "$release_environment" environment
  capture_file "$nginx_configuration" nginx
  if [[ -L "$current" ]]; then
    old_target="$(readlink -f -- "$current")"
    [[ "$old_target" == "$releases"/* ]]
  fi
  if systemctl is-active --quiet identity-stack.service; then
    prior_service_active=true
    [[ -n "$old_target" ]]
    "$verify_release" "$old_target"
    "$health_verify"
  fi

  activation_started=true
  atomic_link "$release" "$current"
  inject_failure current_link
  atomic_file "$release/release.env" "$release_environment" 0600
  inject_failure release_environment
  atomic_file "$generation/identity-runtime.conf.staged" "$nginx_configuration" 0644
  inject_failure nginx_configuration
  nginx -t
  inject_failure nginx_validation
  systemctl reload nginx
  inject_failure nginx_reload
  systemctl restart identity-stack.service
  inject_failure service_restart
  "$verify_release" "$release"
  inject_failure release_verification
  "$health_verify"
  inject_failure health_verification
  if [[ -n "$old_target" && "$old_target" != "$release" ]]; then
    atomic_link "$old_target" "$previous"
  fi
  inject_failure previous_promotion
  activation_committed=true
  rm -rf -- "$transaction"
  transaction=""
}

cleanup() {
  if [[ -n "$transaction" && -d "$transaction" ]]; then
    rm -rf -- "$transaction"
  fi
  if [[ -n "${docker_config:-}" && -d "$docker_config" ]]; then
    rm -rf -- "$docker_config"
  fi
  [[ -z "$recovery_info" ]] || rm -f -- "$recovery_info"
  [[ -z "$recovery_metadata" ]] || rm -f -- "$recovery_metadata"
}
trap cleanup EXIT

if [[ -n "$test_root" && "$1" == --cleanup-fixture ]]; then
  release="${PLATFORM_IDENTITY_FIXTURE_RELEASE:?fixture release required}"
  release_created=true
  preactivation_services_started="${PLATFORM_IDENTITY_FIXTURE_PREACTIVATION_STARTED:-false}"
  [[ "$preactivation_services_started" == true || "$preactivation_services_started" == false ]]
  if ! stop_preactivation_services; then
    printf 'Identity pre-activation service cleanup fixture failed safely.\n' >&2
    exit 1
  fi
  remove_unactivated_release
  printf 'Identity pre-activation cleanup fixture completed.\n'
  exit 0
fi

if [[ -n "$test_root" ]]; then
  readonly fixture_release="${PLATFORM_IDENTITY_FIXTURE_RELEASE:?fixture release required}"
  activate_release "$fixture_release"
  printf 'Identity activation fixture completed.\n'
  exit 0
fi

readonly docker_config="$(mktemp -d /run/platform-identity-docker-auth.XXXXXXXX)"
chmod 0700 "$docker_config"
export DOCKER_CONFIG="$docker_config"

readonly release_id="${SSM_releaseId:?releaseId parameter required}"
readonly api_image="${SSM_apiImage:?apiImage parameter required}"
readonly bff_image="${SSM_bffImage:?bffImage parameter required}"
readonly cognito_issuer="${SSM_issuer:?issuer parameter required}"
readonly cognito_jwks_url="${SSM_jwksUri:?jwksUri parameter required}"
readonly cognito_client_id="${SSM_clientId:?clientId parameter required}"
[[ "$release_id" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]
[[ "${api_image%@sha256:*}" == "$api_repository" && "${api_image##*@sha256:}" =~ ^[0-9a-f]{64}$ ]]
[[ "${bff_image%@sha256:*}" == "$bff_repository" && "${bff_image##*@sha256:}" =~ ^[0-9a-f]{64}$ ]]
[[ "$api_image" != "$bff_image" ]]
[[ "$cognito_issuer" =~ ^https://cognito-idp[.]ap-south-1[.]amazonaws[.]com/ap-south-1_[A-Za-z0-9]+$ ]]
[[ "$cognito_jwks_url" == "$cognito_issuer/.well-known/jwks.json" ]]
[[ "$cognito_client_id" =~ ^[a-z0-9]{26}$ ]]

release="$releases/$release_id"
[[ ! -e "$release" && ! -L "$release" ]]
install -d -m 0755 "$release"
release_created=true
install -m 0644 "$generation/compose.yml" "$release/compose.yml"
printf 'IDENTITY_API_IMAGE=%s\nIDENTITY_BFF_IMAGE=%s\nIDENTITY_RELEASE_ID=%s\nCOGNITO_ISSUER=%s\nCOGNITO_JWKS_URL=%s\nCOGNITO_CLIENT_ID=%s\nIDENTITY_SCHEMA_HEAD=%s\nIDENTITY_ORIGIN=https://identity.rahuly.in\nBFF_ORIGIN=https://rahuly.in\nAUTHORIZATION_ENDPOINT=https://auth.rahuly.in/oauth2/authorize\nTOKEN_ENDPOINT=https://auth.rahuly.in/oauth2/token\nOAUTH_RESOURCE=identity-service://api\nREDIS_KEY_NAMESPACE=reference-bff:production:portfolio:identity\n' \
  "$api_image" "$bff_image" "$release_id" "$cognito_issuer" "$cognito_jwks_url" "$cognito_client_id" "$schema_head" >"$release/release.env"
chmod 0600 "$release/release.env"

export IDENTITY_API_IMAGE="$api_image" IDENTITY_BFF_IMAGE="$bff_image"
export COGNITO_ISSUER="$cognito_issuer" COGNITO_JWKS_URL="$cognito_jwks_url" COGNITO_CLIENT_ID="$cognito_client_id"
images_missing=false
for image in "$api_image" "$bff_image"; do
  if ! docker image inspect "$image" >/dev/null 2>&1; then images_missing=true; fi
done
if [[ "$images_missing" == true ]]; then
  aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin "$ecr_registry" >/dev/null
  for image in "$api_image" "$bff_image"; do
    if ! docker image inspect "$image" >/dev/null 2>&1; then docker pull "$image" >/dev/null; fi
  done
fi
for image in "$api_image" "$bff_image"; do
  [[ "$(docker image inspect --format '{{.Architecture}}/{{.Os}}' "$image")" == arm64/linux ]]
  docker image inspect --format '{{join .RepoDigests "\n"}}' "$image" | grep -Fxq "$image"
done

preactivation_services_started=true
docker compose --file "$release/compose.yml" --project-name identity-production run --rm --no-deps --user 999:999 postgres \
  sh -c 'install -d -m 0700 /var/lib/postgresql/18/docker && chmod 0700 /var/lib/postgresql /var/lib/postgresql/18/docker'
docker compose --file "$release/compose.yml" --project-name identity-production run --rm --no-deps --user root \
  --cap-add CHOWN --cap-add FOWNER postgres \
  sh -c 'chmod 0770 /run/postgresql /var/spool/pgbackrest && chown 999:999 /run/postgresql /var/spool/pgbackrest'
docker compose --file "$release/compose.yml" --project-name identity-production up --detach --wait postgres redis
docker compose --file "$release/compose.yml" --project-name identity-production exec --no-TTY \
  --user 10001:10001 --env PGPASSFILE=/run/secrets/database/bootstrap.pgpass postgres \
  psql "host=postgres port=5432 dbname=identity user=identity_bootstrap sslmode=verify-full sslrootcert=/run/tls/client/ca.crt" \
  < "$generation/postgres-roles.sql"
docker compose --file "$release/compose.yml" --project-name identity-production up --detach pgbackrest
docker compose --file "$release/compose.yml" --project-name identity-production exec --no-TTY pgbackrest pgbackrest --stanza=identity stanza-create
docker compose --file "$release/compose.yml" --project-name identity-production exec --no-TTY pgbackrest pgbackrest --stanza=identity check
docker compose --file "$release/compose.yml" --project-name identity-production run --rm migrator

observed_head="$(docker compose --file "$release/compose.yml" --project-name identity-production exec --no-TTY \
  --env PGPASSFILE=/run/secrets/database/bootstrap.pgpass postgres \
  psql "host=postgres port=5432 dbname=identity user=identity_bootstrap sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt" \
  --no-psqlrc --tuples-only --no-align --command 'SELECT version_num FROM identity.alembic_version;')"
[[ "$observed_head" == "$schema_head" ]]
docker compose --file "$release/compose.yml" --project-name identity-production exec --no-TTY \
  --env PGPASSFILE=/run/secrets/database/bootstrap.pgpass postgres \
  psql "host=postgres port=5432 dbname=identity user=identity_bootstrap sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt" \
  --no-psqlrc --set ON_ERROR_STOP=1 --set IDENTITY_POST_MIGRATION_AUDIT=1 --file "$generation/postgres-roles.sql"

recovery_marker="$(openssl rand -hex 16)"
recovery_marker_created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
docker compose --file "$release/compose.yml" --project-name identity-production exec --no-TTY postgres \
  psql --username identity_bootstrap --dbname identity --no-psqlrc --set ON_ERROR_STOP=1 \
  --set marker="$recovery_marker" --set marker_created_at="$recovery_marker_created_at" <<'SQL'
CREATE SCHEMA IF NOT EXISTS platform_recovery AUTHORIZATION identity_bootstrap;
REVOKE ALL ON SCHEMA platform_recovery FROM PUBLIC, identity_service_owner, identity_service_migrator, identity_service_app;
CREATE TABLE IF NOT EXISTS platform_recovery.markers (
  marker text PRIMARY KEY CHECK (marker ~ '^[0-9a-f]{32}$'),
  created_at timestamptz NOT NULL
);
ALTER TABLE platform_recovery.markers OWNER TO identity_bootstrap;
REVOKE ALL ON TABLE platform_recovery.markers FROM PUBLIC, identity_service_owner, identity_service_migrator, identity_service_app;
INSERT INTO platform_recovery.markers(marker, created_at) VALUES (:'marker', :'marker_created_at'::timestamptz);
CHECKPOINT;
SQL
docker compose --file "$release/compose.yml" --project-name identity-production exec --no-TTY pgbackrest \
  pgbackrest --stanza=identity --type=full backup
docker compose --file "$release/compose.yml" --project-name identity-production exec --no-TTY pgbackrest \
  touch /var/spool/pgbackrest/.last-backup-success
recovery_metadata_root=/var/lib/platform/identity-recovery
install -d -m 0700 "$recovery_metadata_root"
recovery_info="$(mktemp /var/lib/platform/identity-deploy-backup.XXXXXXXX)"
recovery_metadata="$(mktemp /var/lib/platform/identity-deploy-metadata.XXXXXXXX)"
docker compose --file "$release/compose.yml" --project-name identity-production exec --no-TTY pgbackrest \
  pgbackrest --stanza=identity info --output=json >"$recovery_info"
python3 - "$recovery_info" "$recovery_metadata" "$recovery_marker" "$recovery_marker_created_at" <<'PY'
import datetime
import json
import pathlib
import re
import sys
source, destination, marker, created_at = sys.argv[1:]
value = json.loads(pathlib.Path(source).read_text(encoding="utf-8"))
if not isinstance(value, list) or len(value) != 1 or value[0].get("name") != "identity" or not value[0].get("backup"):
    raise SystemExit(2)
latest = value[0]["backup"][-1]
label = latest.get("label")
timestamps = latest.get("timestamp")
if latest.get("type") != "full" or not isinstance(label, str) or not re.fullmatch(r"[0-9]{8}-[0-9]{6}F", label) or not isinstance(timestamps, dict):
    raise SystemExit(2)
start, stop = timestamps.get("start"), timestamps.get("stop")
created = datetime.datetime.strptime(created_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
if not isinstance(start, int) or not isinstance(stop, int) or int(created.timestamp()) > start or stop < start:
    raise SystemExit(2)
metadata = {
    "version": 1, "marker": marker, "marker_created_at": created_at,
    "backup_label": label, "backup_type": "full",
    "backup_started_at": datetime.datetime.fromtimestamp(start, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "backup_stopped_at": datetime.datetime.fromtimestamp(stop, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "schema_head": "0001_initial_identity_schema",
}
pathlib.Path(destination).write_text(json.dumps(metadata, sort_keys=True, separators=(",", ":")) + "\n", encoding="ascii")
PY
chmod 0600 "$recovery_metadata"
recovery_target="$recovery_metadata_root/identity-backup-$(date -u +%Y%m%dT%H%M%SZ).json"
recovery_next="$recovery_metadata_root/.identity-backup.$$.next"
install -m 0600 "$recovery_metadata" "$recovery_next"
mv -Tf -- "$recovery_next" "$recovery_target"
rm -f -- "$recovery_info" "$recovery_metadata"
recovery_info=""
recovery_metadata=""

activate_release "$release"
printf 'Identity deployment completed for an immutable repository-bound ARM64 release.\n'
