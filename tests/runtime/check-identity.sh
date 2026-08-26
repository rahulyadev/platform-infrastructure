#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
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
COGNITO_ISSUER=https://cognito-idp.ap-south-1.amazonaws.com/ap-south-1_example \
COGNITO_JWKS_URI=https://cognito-idp.ap-south-1.amazonaws.com/ap-south-1_example/.well-known/jwks.json \
COGNITO_AUDIENCE=identity-service://api COGNITO_CLIENT_ID=exampleclient \
BFF_ORIGIN=https://rahuly.in docker compose --file "$temporary/compose.yml" config --quiet

grep -Fq 'POSTGRES_INITDB_ARGS: --auth-host=scram-sha-256 --auth-local=reject' config/runtime/identity-compose.yml.tftpl
grep -Fq 'hostnossl all all 0.0.0.0/0 reject' config/runtime/postgres-hba.conf
grep -Fq 'hostssl all all 0.0.0.0/0 scram-sha-256' config/runtime/postgres-hba.conf
[[ "$(grep -Fc 'DATABASE_SSLMODE: verify-full' config/runtime/identity-compose.yml.tftpl)" == 2 ]]
grep -Fq 'REDIS_URL: rediss://redis:6379/0' config/runtime/identity-compose.yml.tftpl
grep -Fq -- '--appendonly' config/runtime/identity-compose.yml.tftpl
grep -Fq -- '- "no"' config/runtime/identity-compose.yml.tftpl
grep -Fq -- '--save' config/runtime/identity-compose.yml.tftpl
grep -Fq -- '- ""' config/runtime/identity-compose.yml.tftpl
! grep -Eq 'ports:.*(5432|6379)' config/runtime/identity-compose.yml.tftpl
! grep -Eq '/var/run/docker.sock|/run/docker.sock' config/runtime/identity-compose.yml.tftpl
grep -Fq 'identity_owner NOLOGIN' config/runtime/postgres-roles.sql
grep -Fq 'identity_migrator LOGIN NOINHERIT' config/runtime/postgres-roles.sql
grep -Fq 'identity_runtime LOGIN NOINHERIT' config/runtime/postgres-roles.sql
grep -Fq 'GRANT SELECT, INSERT, UPDATE ON TABLES TO identity_runtime' config/runtime/postgres-roles.sql
grep -Fq 'PLATFORM-P4-REDIS-RECOVERY-DESIGN-001' docs/production-identity.md
[[ "$(grep -Fc 'driver: awslogs' config/runtime/identity-compose.yml.tftpl)" == 6 ]]
[[ "$(grep -Fc 'network_mode: host' config/runtime/identity-compose.yml.tftpl)" == 1 ]]
! grep -Eq '^pg1-(host|port)=' config/runtime/pgbackrest.conf.tftpl
bash tests/runtime/check-identity-fixtures.sh
printf 'Identity runtime source checks passed.\n'
