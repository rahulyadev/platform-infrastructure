#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
set +x

deployment_failed() {
  local metadata_token instance_id
  metadata_token="$(curl --fail --silent --max-time 3 --request PUT --header 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token 2>/dev/null || true)"
  instance_id="$(curl --fail --silent --max-time 3 --header "X-aws-ec2-metadata-token: $metadata_token" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || true)"
  [[ -n "$instance_id" ]] || return 0
  aws cloudwatch put-metric-data --region ap-south-1 --namespace PlatformInfrastructure/Production/Identity \
    --metric-data "MetricName=IdentityDeploymentFailure,Dimensions=[{Name=InstanceId,Value=$instance_id}],Value=1,Unit=Count" >/dev/null 2>&1 || true
}
trap deployment_failed ERR

readonly release_id="${SSM_releaseId:?releaseId parameter required}"
readonly api_image="${SSM_apiImage:?apiImage parameter required}"
readonly bff_image="${SSM_bffImage:?bffImage parameter required}"
readonly releases=/opt/platform/identity/releases
readonly current=/opt/platform/identity/current
readonly previous=/opt/platform/identity/previous
readonly digest_pattern='^[a-z0-9.-]+(/[a-z0-9/_-]+)+@sha256:[0-9a-f]{64}$'

[[ "$release_id" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]
[[ "$api_image" =~ $digest_pattern ]]
[[ "$bff_image" =~ $digest_pattern ]]

release="$releases/$release_id"
[[ ! -e "$release" ]]
install -d -m 0755 "$release"
install -m 0644 /opt/platform/identity/compose.yml "$release/compose.yml"
readonly cognito_issuer="${SSM_issuer:?issuer parameter required}"
readonly cognito_jwks_uri="${SSM_jwksUri:?jwksUri parameter required}"
readonly cognito_audience="${SSM_audience:?audience parameter required}"
readonly cognito_client_id="${SSM_clientId:?clientId parameter required}"
readonly bff_origin="${SSM_bffOrigin:?bffOrigin parameter required}"
[[ "$cognito_issuer" =~ ^https://cognito-idp[.]ap-south-1[.]amazonaws[.]com/ap-south-1_[A-Za-z0-9]+$ ]]
[[ "$cognito_jwks_uri" == "$cognito_issuer/.well-known/jwks.json" ]]
[[ "$cognito_audience" == identity-service://api ]]
[[ "$cognito_client_id" =~ ^[a-z0-9]+$ ]]
[[ "$bff_origin" == https://rahuly.in ]]
printf 'IDENTITY_API_IMAGE=%s\nIDENTITY_BFF_IMAGE=%s\nIDENTITY_RELEASE_ID=%s\nCOGNITO_ISSUER=%s\nCOGNITO_JWKS_URI=%s\nCOGNITO_AUDIENCE=%s\nCOGNITO_CLIENT_ID=%s\nBFF_ORIGIN=%s\n' \
  "$api_image" "$bff_image" "$release_id" "$cognito_issuer" "$cognito_jwks_uri" "$cognito_audience" "$cognito_client_id" "$bff_origin" >"$release/release.env"
chmod 0600 "$release/release.env"

export IDENTITY_API_IMAGE="$api_image" IDENTITY_BFF_IMAGE="$bff_image"
docker pull "$api_image"
docker pull "$bff_image"
[[ "$(docker image inspect --format '{{.Architecture}}' "$api_image")" == arm64 ]]
[[ "$(docker image inspect --format '{{.Architecture}}' "$bff_image")" == arm64 ]]

docker compose --file "$release/compose.yml" --project-name identity-production run --rm --no-deps --user root postgres \
  sh -c 'chown 999:999 /run/postgresql /var/spool/pgbackrest && chmod 0770 /run/postgresql /var/spool/pgbackrest'
docker compose --file "$release/compose.yml" --project-name identity-production up --detach --wait postgres redis
docker compose --file "$release/compose.yml" --project-name identity-production exec --no-TTY \
  --env PGPASSFILE=/run/secrets/database/bootstrap.pgpass postgres \
  psql "host=postgres port=5432 dbname=identity user=identity_bootstrap sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt" \
  < /opt/platform/identity/postgres-roles.sql
docker compose --file "$release/compose.yml" --project-name identity-production up --detach pgbackrest
docker compose --file "$release/compose.yml" --project-name identity-production exec --no-TTY \
  pgbackrest pgbackrest --stanza=identity stanza-create
docker compose --file "$release/compose.yml" --project-name identity-production exec --no-TTY \
  pgbackrest pgbackrest --stanza=identity check
docker compose --file "$release/compose.yml" --project-name identity-production run --rm migrator
docker compose --file "$release/compose.yml" --project-name identity-production run --rm migrator check
docker compose --file "$release/compose.yml" --project-name identity-production exec --no-TTY \
  pgbackrest pgbackrest --stanza=identity --type=full backup
docker compose --file "$release/compose.yml" --project-name identity-production exec --no-TTY \
  pgbackrest touch /var/spool/pgbackrest/.last-backup-success

old_target=""
if [[ -L "$current" ]]; then
  old_target="$(readlink -f -- "$current")"
fi
ln -sfn -- "$release" "$current.next"
mv -Tf -- "$current.next" "$current"
install -m 0600 "$release/release.env" /etc/platform/identity/release.env
install -m 0644 /etc/nginx/conf.d/identity-runtime.conf.staged /etc/nginx/conf.d/identity-runtime.conf
nginx -t
systemctl reload nginx
systemctl restart identity-stack.service

if [[ -n "$old_target" && "$old_target" != "$release" ]]; then
  ln -sfn -- "$old_target" "$previous.next"
  mv -Tf -- "$previous.next" "$previous"
fi

/usr/local/libexec/platform/identity-health-verify
printf 'Identity deployment completed for an immutable release.\n'
