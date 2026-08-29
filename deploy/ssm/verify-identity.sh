#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
set +x

docker_template_open="$(printf '%s%s' '{' '{')"
docker_template_close="$(printf '%s%s' '}' '}')"
readonly docker_template_open docker_template_close
readonly docker_running_template="${docker_template_open}.State.Running${docker_template_close}"
readonly docker_health_template="${docker_template_open}if .State.Health${docker_template_close}${docker_template_open}.State.Health.Status${docker_template_close}${docker_template_open}end${docker_template_close}"
readonly docker_health_status_template="${docker_template_open}.State.Health.Status${docker_template_close}"
readonly docker_restart_template="${docker_template_open}.RestartCount${docker_template_close}"

readonly compose_file=/opt/platform/identity/current/compose.yml
readonly project=identity-production
readonly restart_state=/var/lib/platform/identity-container-restarts
readonly metadata_token="$(curl --fail --silent --show-error --max-time 3 --request PUT \
  --header 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)"
readonly instance_id="$(curl --fail --silent --show-error --max-time 3 \
  --header "X-aws-ec2-metadata-token: $metadata_token" http://169.254.169.254/latest/meta-data/instance-id)"
readonly -a compose=(docker compose --file "$compose_file" --project-name "$project")
stage=IdentityContainerFailure

publish_metric() {
  local metric="$1"
  local value="$2"
  aws cloudwatch put-metric-data --region ap-south-1 --namespace PlatformInfrastructure/Production/Identity \
    --metric-data "MetricName=$metric,Dimensions=[{Name=InstanceId,Value=$instance_id}],Value=$value,Unit=Count" >/dev/null
}

verification_failed() {
  local status=$?
  trap - ERR
  publish_metric "$stage" 1 >/dev/null 2>&1 || true
  printf 'Identity verification failed safely.\n' >&2
  exit "$status"
}
trap verification_failed ERR

stage=IdentityApiHealthFailure
curl --fail --silent --show-error --max-time 5 --noproxy '*' http://127.0.0.1:8081/health/ready >/dev/null
stage=IdentityBffHealthFailure
curl --fail --silent --show-error --max-time 5 --noproxy '*' http://127.0.0.1:8082/health/ready >/dev/null

stage=IdentityContainerFailure
mapfile -t container_ids < <("${compose[@]}" ps --quiet)
[[ "${#container_ids[@]}" == 5 ]]
for container_id in "${container_ids[@]}"; do
  [[ "$(docker inspect --format "$docker_running_template" "$container_id")" == true ]]
  health="$(docker inspect --format "$docker_health_template" "$container_id")"
  [[ -z "$health" || "$health" == healthy ]]
done

stage=IdentityContainerRestart
restart_total=0
for container_id in "${container_ids[@]}"; do
  restart_total=$((restart_total + $(docker inspect --format "$docker_restart_template" "$container_id")))
done
if [[ -f "$restart_state" ]]; then
  read -r prior_restart_total <"$restart_state"
  [[ "$prior_restart_total" =~ ^[0-9]+$ ]]
  [[ "$restart_total" -le "$prior_restart_total" ]]
fi
printf '%s\n' "$restart_total" >"$restart_state.tmp"
chmod 0600 "$restart_state.tmp"
mv -f -- "$restart_state.tmp" "$restart_state"

stage=IdentityMemoryPressure
awk '/MemTotal:/ { total=$2 } /MemAvailable:/ { available=$2 } END { exit !(total > 0 && available * 100 / total >= 10) }' /proc/meminfo
stage=IdentityDiskPressure
df -P / | awk 'NR == 2 { gsub(/%/, "", $5); exit !($5 < 85) }'

stage=IdentityPostgresReachabilityFailure
postgres_id="$("${compose[@]}" ps --quiet postgres)"
[[ -n "$postgres_id" && "$(docker inspect --format "$docker_health_status_template" "$postgres_id")" == healthy ]]
stage=IdentityRedisReachabilityFailure
redis_id="$("${compose[@]}" ps --quiet redis)"
[[ -n "$redis_id" && "$(docker inspect --format "$docker_health_status_template" "$redis_id")" == healthy ]]
redis_probe="reference-bff:production:portfolio:identity:verifier:$RANDOM$RANDOM"
"${compose[@]}" exec --no-TTY redis sh -eu -c '
  export REDISCLI_AUTH="$(cat /run/secrets/redis/bff_password)"
  cli="redis-cli --tls --sni redis --user portfolio_bff --cacert /run/tls/redis/ca.crt"
  $cli SET "$1:set" value EX 60 >/dev/null
  test "$($cli GET "$1:set")" = value
  test "$($cli GETDEL "$1:set")" = value
  $cli SET "$1:del" value EX 60 >/dev/null
  test "$($cli DEL "$1:del")" = 1
  $cli SET "$1:eval" value EX 60 >/dev/null
  test "$($cli EVAL "return redis.call('"'"'GET'"'"', KEYS[1])" 1 "$1:eval")" = value
  test "$($cli EVAL "return redis.call('"'"'DEL'"'"', KEYS[1])" 1 "$1:eval")" = 1
' sh "$redis_probe"

stage=IdentityMigrationFailure
observed_head="$("${compose[@]}" exec --no-TTY --env PGPASSFILE=/run/secrets/database/bootstrap.pgpass postgres \
  psql 'host=postgres port=5432 dbname=identity user=identity_bootstrap sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt' \
  --no-psqlrc --tuples-only --no-align --command 'SELECT version_num FROM identity.alembic_version;')"
[[ "$observed_head" == 0001_initial_identity_schema ]]
stage=IdentityBackupStale
"${compose[@]}" exec --no-TTY pgbackrest sh -eu -c \
  'test -f /var/spool/pgbackrest/.last-backup-success; age=$(($(date +%s)-$(stat -c %Y /var/spool/pgbackrest/.last-backup-success))); test "$age" -le 86400'

stage=IdentityWalArchiveStale
"${compose[@]}" exec --no-TTY postgres psql --username identity_bootstrap --dbname identity \
  --no-psqlrc --tuples-only --command 'SELECT pg_switch_wal();' >/dev/null
wal_fresh=false
for _ in {1..30}; do
  if "${compose[@]}" exec --no-TTY pgbackrest sh -eu -c \
    'test -f /var/spool/pgbackrest/.last-archive-success; age=$(($(date +%s)-$(stat -c %Y /var/spool/pgbackrest/.last-archive-success))); test "$age" -le 60' >/dev/null 2>&1; then
    wal_fresh=true
    break
  fi
  sleep 1
done
[[ "$wal_fresh" == true ]]

stage=IdentityCertificateExpiry
openssl x509 -checkend 1209600 -noout -in /etc/letsencrypt/live/rahuly.in/fullchain.pem >/dev/null
openssl x509 -checkend 1209600 -noout -in /etc/letsencrypt/live/identity.rahuly.in/fullchain.pem >/dev/null

for metric in \
  IdentityApiHealthFailure IdentityBffHealthFailure IdentityPostgresReachabilityFailure \
  IdentityRedisReachabilityFailure IdentityContainerRestart IdentityContainerFailure \
  IdentityMemoryPressure IdentityDiskPressure IdentityMigrationFailure IdentityBackupStale \
  IdentityWalArchiveStale IdentityDeploymentFailure IdentityCertificateExpiry; do
  publish_metric "$metric" 0
done
printf 'Identity health, capacity, migration, backup, WAL, and certificate verification passed.\n'
