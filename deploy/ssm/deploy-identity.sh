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

readonly docker_config="$(mktemp -d /run/platform-identity-docker-auth.XXXXXXXX)"
chmod 0700 "$docker_config"
cleanup() {
  rm -rf -- "$docker_config"
}
trap cleanup EXIT
export DOCKER_CONFIG="$docker_config"

readonly api_repository='__IDENTITY_API_REPOSITORY_URL__'
readonly bff_repository='__IDENTITY_BFF_REPOSITORY_URL__'
readonly ecr_registry='__IDENTITY_ECR_REGISTRY__'
readonly release_id="${SSM_releaseId:?releaseId parameter required}"
readonly api_image="${SSM_apiImage:?apiImage parameter required}"
readonly bff_image="${SSM_bffImage:?bffImage parameter required}"
readonly cognito_issuer="${SSM_issuer:?issuer parameter required}"
readonly cognito_jwks_url="${SSM_jwksUri:?jwksUri parameter required}"
readonly cognito_client_id="${SSM_clientId:?clientId parameter required}"
readonly releases=/opt/platform/identity/releases
readonly current=/opt/platform/identity/current
readonly previous=/opt/platform/identity/previous
readonly schema_head=0001_initial_identity_schema

[[ "$release_id" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]
[[ "${api_image%@sha256:*}" == "$api_repository" && "${api_image##*@sha256:}" =~ ^[0-9a-f]{64}$ ]]
[[ "${bff_image%@sha256:*}" == "$bff_repository" && "${bff_image##*@sha256:}" =~ ^[0-9a-f]{64}$ ]]
[[ "$api_image" != "$bff_image" ]]
[[ "$cognito_issuer" =~ ^https://cognito-idp[.]ap-south-1[.]amazonaws[.]com/ap-south-1_[A-Za-z0-9]+$ ]]
[[ "$cognito_jwks_url" == "$cognito_issuer/.well-known/jwks.json" ]]
[[ "$cognito_client_id" =~ ^[a-z0-9]{26}$ ]]

release="$releases/$release_id"
[[ ! -e "$release" ]]
install -d -m 0755 "$release"
install -m 0644 /etc/platform/identity/compose.yml "$release/compose.yml"
printf 'IDENTITY_API_IMAGE=%s\nIDENTITY_BFF_IMAGE=%s\nIDENTITY_RELEASE_ID=%s\nCOGNITO_ISSUER=%s\nCOGNITO_JWKS_URL=%s\nCOGNITO_CLIENT_ID=%s\nIDENTITY_SCHEMA_HEAD=%s\nIDENTITY_ORIGIN=https://identity.rahuly.in\nBFF_ORIGIN=https://rahuly.in\nAUTHORIZATION_ENDPOINT=https://auth.rahuly.in/oauth2/authorize\nTOKEN_ENDPOINT=https://auth.rahuly.in/oauth2/token\nOAUTH_RESOURCE=identity-service://api\nREDIS_KEY_NAMESPACE=reference-bff:production:portfolio:identity\n' \
  "$api_image" "$bff_image" "$release_id" "$cognito_issuer" "$cognito_jwks_url" "$cognito_client_id" "$schema_head" >"$release/release.env"
chmod 0600 "$release/release.env"

aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin "$ecr_registry" >/dev/null
export IDENTITY_API_IMAGE="$api_image" IDENTITY_BFF_IMAGE="$bff_image"
export COGNITO_ISSUER="$cognito_issuer" COGNITO_JWKS_URL="$cognito_jwks_url" COGNITO_CLIENT_ID="$cognito_client_id"
docker pull "$api_image" >/dev/null
docker pull "$bff_image" >/dev/null
for image in "$api_image" "$bff_image"; do
  [[ "$(docker image inspect --format '{{.Architecture}}/{{.Os}}' "$image")" == arm64/linux ]]
  docker image inspect --format '{{join .RepoDigests "\n"}}' "$image" | grep -Fxq "$image"
done

docker compose --file "$release/compose.yml" --project-name identity-production run --rm --no-deps --user root postgres \
  sh -c 'chown 999:999 /run/postgresql /var/spool/pgbackrest && chmod 0770 /run/postgresql /var/spool/pgbackrest'
docker compose --file "$release/compose.yml" --project-name identity-production up --detach --wait postgres redis
docker compose --file "$release/compose.yml" --project-name identity-production exec --no-TTY \
  --user 10001:10001 \
  --env PGPASSFILE=/run/secrets/database/bootstrap.pgpass postgres \
  psql "host=postgres port=5432 dbname=identity user=identity_bootstrap sslmode=verify-full sslrootcert=/run/tls/client/ca.crt" \
  < /etc/platform/identity/postgres-roles.sql
docker compose --file "$release/compose.yml" --project-name identity-production up --detach pgbackrest
docker compose --file "$release/compose.yml" --project-name identity-production exec --no-TTY pgbackrest \
  pgbackrest --stanza=identity stanza-create
docker compose --file "$release/compose.yml" --project-name identity-production exec --no-TTY pgbackrest \
  pgbackrest --stanza=identity check
docker compose --file "$release/compose.yml" --project-name identity-production run --rm migrator
observed_head="$(docker compose --file "$release/compose.yml" --project-name identity-production exec --no-TTY \
  --env PGPASSFILE=/run/secrets/database/bootstrap.pgpass postgres \
  psql "host=postgres port=5432 dbname=identity user=identity_bootstrap sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt" \
  --no-psqlrc --tuples-only --no-align --command 'SELECT version_num FROM identity.alembic_version;')"
[[ "$observed_head" == "$schema_head" ]]
docker compose --file "$release/compose.yml" --project-name identity-production exec --no-TTY pgbackrest \
  pgbackrest --stanza=identity --type=full backup
docker compose --file "$release/compose.yml" --project-name identity-production exec --no-TTY pgbackrest \
  touch /var/spool/pgbackrest/.last-backup-success

old_target=""
if [[ -L "$current" ]]; then
  old_target="$(readlink -f -- "$current")"
fi
ln -s -- "$release" "$current.next"
mv -Tf -- "$current.next" "$current"
install -m 0600 "$release/release.env" /etc/platform/identity/release.env
install -m 0644 /etc/platform/identity/identity-runtime.conf.staged /etc/nginx/conf.d/identity-runtime.conf
nginx -t
systemctl reload nginx
systemctl restart identity-stack.service

if [[ -n "$old_target" && "$old_target" != "$release" ]]; then
  ln -s -- "$old_target" "$previous.next"
  mv -Tf -- "$previous.next" "$previous"
fi
/usr/local/libexec/platform/identity-health-verify
printf 'Identity deployment completed for an immutable repository-bound ARM64 release.\n'
