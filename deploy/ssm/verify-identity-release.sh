#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
set +x

readonly release_file=/etc/platform/identity/release.env
readonly api_repository='__IDENTITY_API_REPOSITORY_URL__'
readonly bff_repository='__IDENTITY_BFF_REPOSITORY_URL__'
[[ -f "$release_file" && ! -L "$release_file" ]]
[[ "$(stat -c '%a:%u:%g' "$release_file")" == 600:0:0 ]]

declare -A release=()
while IFS='=' read -r key value; do
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ && -n "$value" && "$value" != *[[:space:]]* ]]
  [[ ! -v "release[$key]" ]]
  case "$key" in
    IDENTITY_API_IMAGE|IDENTITY_BFF_IMAGE|IDENTITY_RELEASE_ID|COGNITO_ISSUER|COGNITO_JWKS_URL|COGNITO_CLIENT_ID|IDENTITY_SCHEMA_HEAD|IDENTITY_ORIGIN|BFF_ORIGIN|AUTHORIZATION_ENDPOINT|TOKEN_ENDPOINT|OAUTH_RESOURCE|REDIS_KEY_NAMESPACE) ;;
    *) exit 1 ;;
  esac
  release["$key"]="$value"
done <"$release_file"
[[ "${#release[@]}" == 13 ]]

readonly api_image="${release[IDENTITY_API_IMAGE]}"
readonly bff_image="${release[IDENTITY_BFF_IMAGE]}"
[[ "${api_image%@sha256:*}" == "$api_repository" && "${api_image##*@sha256:}" =~ ^[0-9a-f]{64}$ ]]
[[ "${bff_image%@sha256:*}" == "$bff_repository" && "${bff_image##*@sha256:}" =~ ^[0-9a-f]{64}$ ]]
[[ "${release[IDENTITY_RELEASE_ID]}" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]
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
[[ "$(docker image inspect --format '{{.Architecture}}/{{.Os}}' "$api_image")" == arm64/linux ]]
[[ "$(docker image inspect --format '{{.Architecture}}/{{.Os}}' "$bff_image")" == arm64/linux ]]
