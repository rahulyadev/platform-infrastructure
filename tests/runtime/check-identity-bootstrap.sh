#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
set +x

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd -- "$repository_root"
temporary="$(mktemp -d)"
chmod 0700 "$temporary"
trap 'rm -rf -- "$temporary"' EXIT

sed \
  -e 's#${postgres_image}#postgres@sha256:a02db8cac496f15b094798a38254f14d6e00741f709360e5e00bb6668ea31636#g' \
  -e 's#${redis_image}#redis@sha256:5fa2edb1e408fa8235e6db8fab01d1afaaae96c9403ba67b70feceb8661e8621#g' \
  -e 's#${pgbackrest_image}#woblerr/pgbackrest@sha256:c5bc798fdbee479fc23fd419221755f8f0a97756f3a830ec7cc0c6678067e846#g' \
  -e 's#${aws_region}#ap-south-1#g' \
  -e 's#${name_prefix}#platform-infrastructure-production#g' \
  -e 's/$${/${/g' config/runtime/identity-compose.yml.tftpl >"$temporary/compose.yml"

IDENTITY_API_IMAGE=registry.example/identity-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
IDENTITY_BFF_IMAGE=registry.example/identity-bff@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
COGNITO_ISSUER=https://cognito-idp.ap-south-1.amazonaws.com/ap-south-1_Example123 \
COGNITO_JWKS_URL=https://cognito-idp.ap-south-1.amazonaws.com/ap-south-1_Example123/.well-known/jwks.json \
COGNITO_CLIENT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaa \
docker compose --file "$temporary/compose.yml" --profile administration --profile migration config --format json >"$temporary/compose.json"

python3 tests/runtime/test-identity-bootstrap.py "$repository_root" "$temporary/compose.json"
printf 'Production Identity hardened PostgreSQL client contract passed.\n'
