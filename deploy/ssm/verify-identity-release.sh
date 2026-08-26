#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
set +x

readonly release_file=/etc/platform/identity/release.env
readonly digest_pattern='^[a-z0-9.-]+(/[a-z0-9/_-]+)+@sha256:[0-9a-f]{64}$'
[[ -f "$release_file" && ! -L "$release_file" ]]
[[ "$(stat -c '%a' "$release_file")" == 600 ]]
source "$release_file"
[[ "${IDENTITY_API_IMAGE:-}" =~ $digest_pattern ]]
[[ "${IDENTITY_BFF_IMAGE:-}" =~ $digest_pattern ]]
[[ "${IDENTITY_RELEASE_ID:-}" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]
