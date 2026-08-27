#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
set +x

readonly api_repository='__IDENTITY_API_REPOSITORY_URL__'
readonly bff_repository='__IDENTITY_BFF_REPOSITORY_URL__'
metadata_fixture=false
releases=/opt/platform/identity/releases
current=/opt/platform/identity/current
expected_uid=0
expected_gid=0
expected_file_uid=0
expected_file_gid=0

fail() {
  trap - ERR
  printf 'Identity release verification failed safely.\n' >&2
  exit 1
}
trap fail ERR

if [[ "${1:-}" == --metadata-fixture ]]; then
  (($# == 2)) || fail
  fixture_root="${PLATFORM_IDENTITY_RELEASE_TEST_ROOT:?release fixture root required}"
  [[ "$fixture_root" == /tmp/* && -d "$fixture_root" && ! -L "$fixture_root" ]]
  [[ "$fixture_root" == "$(realpath -e -- "$fixture_root")" ]]
  [[ "$(stat -c '%a:%u:%g' "$fixture_root")" == "700:$(id -u):$(id -g)" ]]
  releases="$fixture_root/releases"
  current="$fixture_root/current"
  expected_uid="$(id -u)"
  expected_gid="$(id -g)"
  expected_file_uid="$expected_uid"
  expected_file_gid="${PLATFORM_IDENTITY_RELEASE_TEST_EXPECTED_FILE_GID:-$expected_gid}"
  [[ "$expected_file_gid" =~ ^[0-9]+$ ]]
  candidate="$2"
  metadata_fixture=true
elif (($# == 1)); then
  candidate="$1"
elif (($# == 0)); then
  [[ -L "$current" ]]
  candidate="$(readlink -f -- "$current")"
else
  fail
fi

readonly releases current expected_uid expected_gid expected_file_uid expected_file_gid candidate
[[ -d "$releases" && ! -L "$releases" ]]
[[ "$releases" == "$(realpath -e -- "$releases")" ]]
[[ "$(stat -c '%a:%u:%g' "$releases")" == "755:$expected_uid:$expected_gid" ]]
[[ "$candidate" == "$releases"/* ]]
[[ -d "$candidate" && ! -L "$candidate" ]]
[[ "$candidate" == "$(realpath -e -- "$candidate")" ]]
[[ "$(dirname -- "$candidate")" == "$releases" ]]
[[ "$(basename -- "$candidate")" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]
[[ "$(stat -c '%a:%u:%g' "$candidate")" == "755:$expected_uid:$expected_gid" ]]

mapfile -t candidate_inventory < <(find "$candidate" -mindepth 1 -maxdepth 1 -printf '%f:%y\n' | LC_ALL=C sort)
[[ "${#candidate_inventory[@]}" == 2 ]]
[[ "${candidate_inventory[0]}" == compose.yml:f ]]
[[ "${candidate_inventory[1]}" == release.env:f ]]

readonly release_file="$candidate/release.env"
readonly compose_file="$candidate/compose.yml"
[[ -f "$release_file" && ! -L "$release_file" ]]
[[ -f "$compose_file" && ! -L "$compose_file" ]]
[[ "$(stat -c '%a:%u:%g' "$release_file")" == "600:$expected_file_uid:$expected_file_gid" ]]
[[ "$(stat -c '%a:%u:%g' "$compose_file")" == "644:$expected_file_uid:$expected_file_gid" ]]

if [[ "$metadata_fixture" == true ]]; then
  trap - ERR
  printf 'Identity release metadata fixture passed.\n'
  exit 0
fi

declare -A release=()
while IFS='=' read -r key value; do
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ && -n "$value" && "$value" != *[[:space:]]* ]]
  [[ ! -v "release[$key]" ]]
  case "$key" in
    IDENTITY_API_IMAGE|IDENTITY_BFF_IMAGE|IDENTITY_RELEASE_ID|COGNITO_ISSUER|COGNITO_JWKS_URL|COGNITO_CLIENT_ID|IDENTITY_SCHEMA_HEAD|IDENTITY_ORIGIN|BFF_ORIGIN|AUTHORIZATION_ENDPOINT|TOKEN_ENDPOINT|OAUTH_RESOURCE|REDIS_KEY_NAMESPACE) ;;
    *) fail ;;
  esac
  release["$key"]="$value"
done <"$release_file"
[[ "${#release[@]}" == 13 ]]

readonly api_image="${release[IDENTITY_API_IMAGE]}"
readonly bff_image="${release[IDENTITY_BFF_IMAGE]}"
[[ "${api_image%@sha256:*}" == "$api_repository" && "${api_image##*@sha256:}" =~ ^[0-9a-f]{64}$ ]]
[[ "${bff_image%@sha256:*}" == "$bff_repository" && "${bff_image##*@sha256:}" =~ ^[0-9a-f]{64}$ ]]
[[ "${release[IDENTITY_RELEASE_ID]}" == "$(basename -- "$candidate")" ]]
[[ "${release[COGNITO_ISSUER]}" =~ ^https://cognito-idp[.]ap-south-1[.]amazonaws[.]com/ap-south-1_[A-Za-z0-9]+$ ]]
[[ "${release[COGNITO_JWKS_URL]}" == "${release[COGNITO_ISSUER]}/.well-known/jwks.json" ]]
[[ "${release[COGNITO_CLIENT_ID]}" =~ ^[a-z0-9]{26}$ ]]
[[ "${release[IDENTITY_SCHEMA_HEAD]}" == 0001_initial_identity_schema ]]
[[ "${release[IDENTITY_ORIGIN]}" == https://identity.rahuly.in ]]
[[ "${release[BFF_ORIGIN]}" == https://rahuly.in ]]
[[ "${release[AUTHORIZATION_ENDPOINT]}" == https://auth.rahuly.in/oauth2/authorize ]]
[[ "${release[TOKEN_ENDPOINT]}" == https://auth.rahuly.in/oauth2/token ]]
[[ "${release[OAUTH_RESOURCE]}" == identity-service://api ]]
[[ "${release[REDIS_KEY_NAMESPACE]}" == reference-bff:production:portfolio:identity ]]

docker compose --file "$compose_file" --project-name identity-production config --quiet
[[ "$(docker image inspect --format '{{.Architecture}}/{{.Os}}' "$api_image")" == arm64/linux ]]
[[ "$(docker image inspect --format '{{.Architecture}}/{{.Os}}' "$bff_image")" == arm64/linux ]]
docker image inspect --format '{{join .RepoDigests "\n"}}' "$api_image" | grep -Fxq "$api_image"
docker image inspect --format '{{join .RepoDigests "\n"}}' "$bff_image" | grep -Fxq "$bff_image"
