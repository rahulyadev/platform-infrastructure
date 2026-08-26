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

PYTHONPYCACHEPREFIX="$temporary/pycache" python3 -m py_compile config/runtime/identity-launcher.py
python3 tests/runtime/verify-identity-contract.py .
bash tests/runtime/check-identity-mutations.sh

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
docker compose --file "$temporary/compose.yml" config --quiet

! grep -Eq 'ports:.*(5432|6379)' config/runtime/identity-compose.yml.tftpl
! grep -Eq '/var/run/docker.sock|/run/docker.sock' config/runtime/identity-compose.yml.tftpl
[[ "$(grep -Fc 'driver: awslogs' config/runtime/identity-compose.yml.tftpl)" == 6 ]]
[[ "$(grep -Fc 'network_mode: host' config/runtime/identity-compose.yml.tftpl)" == 1 ]]
! grep -Eq '^pg1-(host|port)=' config/runtime/pgbackrest.conf.tftpl

bash tests/runtime/check-identity-fixtures.sh
printf 'Production Identity runtime and packed immutable-application checks passed.\n'
