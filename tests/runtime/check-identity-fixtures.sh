#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
set +x

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd -- "$repository_root"
docker info >/dev/null 2>&1 || {
  printf 'Identity Docker fixtures require an available local Docker daemon.\n' >&2
  exit 1
}
published_export="${IDENTITY_PUBLISHED_EXPORT:?immutable Identity export path required}"
[[ -f "$published_export/Dockerfile" && -f "$published_export/examples/reference_bff/Dockerfile" ]]

prefix="platform-p3i4-fixture-$$"
network="$prefix"
postgres="$prefix-postgres"
restore="$prefix-restore"
archiver="$prefix-archiver"
redis="$prefix-redis"
bff="$prefix-bff"
fake="$prefix-fake-upstream"
data_volume="$prefix-data"
socket_volume="$prefix-socket"
spool_volume="$prefix-spool"
repository_volume="$prefix-repository"
restore_volume="$prefix-restore"
postgres_tls_volume="$prefix-postgres-tls"
redis_tls_volume="$prefix-redis-tls"
pgbackrest_config_volume="$prefix-pgbackrest-config"
restore_socket_volume="$prefix-restore-socket"
restore_spool_volume="$prefix-restore-spool"
temporary="$(mktemp -d)"
chmod 0700 "$temporary"
stage=setup
api_image="$prefix-api:published"
bff_image="$prefix-bff:published"
host_uid="$(id -u)"
host_gid="$(id -g)"

fixture_failed() {
  printf 'Identity Docker fixture failed safely at stage=%s.\n' "$stage" >&2
}

cleanup() {
  docker rm -f "$postgres" "$restore" "$archiver" "$redis" "$bff" "$fake" >/dev/null 2>&1 || true
  docker volume rm "$data_volume" "$socket_volume" "$spool_volume" "$repository_volume" "$restore_volume" "$postgres_tls_volume" "$redis_tls_volume" "$pgbackrest_config_volume" "$restore_socket_volume" "$restore_spool_volume" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker image rm -f "$api_image" "$bff_image" >/dev/null 2>&1 || true
  docker run --rm --user 0:0 --mount "type=bind,src=$temporary,dst=/cleanup" \
    --entrypoint /bin/sh "$postgres_image" -c "chown -R $host_uid:$host_gid /cleanup && chmod -R u+rwX /cleanup" >/dev/null 2>&1 || true
  rm -rf -- "$temporary"
}
trap fixture_failed ERR
trap cleanup EXIT

postgres_image='postgres@sha256:a02db8cac496f15b094798a38254f14d6e00741f709360e5e00bb6668ea31636'
redis_image='redis@sha256:5fa2edb1e408fa8235e6db8fab01d1afaaae96c9403ba67b70feceb8661e8621'
pgbackrest_image='woblerr/pgbackrest@sha256:c5bc798fdbee479fc23fd419221755f8f0a97756f3a830ec7cc0c6678067e846'

stage=published_image_build
docker build --quiet --target runtime --tag "$api_image" "$published_export" >/dev/null
docker build --quiet --target runtime --file "$published_export/examples/reference_bff/Dockerfile" --tag "$bff_image" "$published_export" >/dev/null
[[ "$(docker image inspect --format '{{.Config.User}}:{{.Config.ExposedPorts}}:{{json .Config.Healthcheck.Test}}:{{json .Config.Cmd}}' "$api_image")" == '10001:10001:map[8080/tcp:{}]:["CMD","python","scripts/healthcheck.py"]:["python","-m","identity_service.server"]' ]]
[[ "$(docker image inspect --format '{{.Config.User}}:{{.Config.ExposedPorts}}:{{json .Config.Healthcheck.Test}}:{{json .Config.Cmd}}' "$bff_image")" == '10002:10002:map[8081/tcp:{}]:["CMD","python","scripts/healthcheck.py"]:["python","-m","reference_bff.server"]' ]]

docker network create --internal "$network" >/dev/null
for volume in "$data_volume" "$socket_volume" "$spool_volume" "$repository_volume" "$restore_volume" "$postgres_tls_volume" "$redis_tls_volume" "$pgbackrest_config_volume" "$restore_socket_volume" "$restore_spool_volume"; do
  docker volume create "$volume" >/dev/null
done

make_tls_identity() {
  local identity="$1"
  local directory="$temporary/$identity"
  mkdir -p "$directory"
  openssl genrsa -out "$directory/ca.key" 2048 >/dev/null 2>&1
  openssl req -x509 -new -key "$directory/ca.key" -days 1 -subj "/CN=$identity-fixture-ca" \
    -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -out "$directory/ca.crt" >/dev/null 2>&1
  openssl genrsa -out "$directory/server.key" 2048 >/dev/null 2>&1
  openssl req -new -key "$directory/server.key" -subj "/CN=$identity" -out "$directory/server.csr" >/dev/null 2>&1
  printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$identity" >"$directory/server.ext"
  openssl x509 -req -in "$directory/server.csr" -CA "$directory/ca.crt" -CAkey "$directory/ca.key" -CAcreateserial -days 1 -extfile "$directory/server.ext" -out "$directory/server.crt" >/dev/null 2>&1
  chmod 0444 "$directory/ca.crt" "$directory/server.crt"
  chmod 0400 "$directory/server.key"
}

make_tls_identity postgres
make_tls_identity redis

mkdir -p "$temporary/upstream"
cp "$temporary/redis/ca.crt" "$temporary/upstream/ca.crt"
openssl genrsa -out "$temporary/upstream/server.key" 2048 >/dev/null 2>&1
openssl req -new -key "$temporary/upstream/server.key" -subj '/CN=fixture-upstream' -out "$temporary/upstream/server.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:auth.rahuly.in,DNS:cognito-idp.ap-south-1.amazonaws.com,DNS:identity.rahuly.in\nextendedKeyUsage=serverAuth\n' >"$temporary/upstream/server.ext"
openssl x509 -req -in "$temporary/upstream/server.csr" -CA "$temporary/redis/ca.crt" -CAkey "$temporary/redis/ca.key" -CAcreateserial -days 1 -extfile "$temporary/upstream/server.ext" -out "$temporary/upstream/server.crt" >/dev/null 2>&1
cat >"$temporary/upstream/server.py" <<'PY'
import base64
import http.server
import json
import ssl
from cryptography import x509

certificate = x509.load_pem_x509_certificate(open("/fixture/ca.crt", "rb").read())
numbers = certificate.public_key().public_numbers()
encode = lambda value: base64.urlsafe_b64encode(value.to_bytes((value.bit_length() + 7) // 8, "big")).rstrip(b"=").decode("ascii")
jwks = json.dumps({"keys": [{"kty": "RSA", "kid": "fixture-key", "use": "sig", "alg": "RS256", "key_ops": ["verify"], "n": encode(numbers.n), "e": encode(numbers.e)}]}, separators=(",", ":")).encode()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = jwks if self.path.endswith("/.well-known/jwks.json") else b"{}"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "max-age=300")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_args):
        return

server = http.server.ThreadingHTTPServer(("0.0.0.0", 443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain("/fixture/server.crt", "/fixture/server.key")
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
PY
cat >"$temporary/component-probe.py" <<'PY'
import os
from pathlib import Path

for item in Path("/proc/1/environ").read_bytes().split(b"\0"):
    if b"=" in item:
        key, value = item.split(b"=", 1)
        os.environ[key.decode()] = value.decode()

import asyncio
import socket
import ssl
from reference_bff.config import Settings
from reference_bff.http import AsyncUpstreamClient
from reference_bff.jwks import AsyncJwksCache
from reference_bff.store import RedisTransactionStore

async def main():
    bundle = Path(os.environ["SSL_CERT_FILE"])
    if not bundle.read_bytes().rstrip().endswith(Path("/run/tls/redis/ca.crt").read_bytes().rstrip()):
        return 94
    try:
        with socket.create_connection(("redis", 6379), timeout=2) as raw:
            with ssl.create_default_context().wrap_socket(raw, server_hostname="redis"):
                pass
    except ssl.SSLCertVerificationError:
        try:
            with socket.create_connection(("redis", 6379), timeout=2) as raw:
                with ssl.create_default_context(cafile=str(bundle)).wrap_socket(raw, server_hostname="redis"):
                    pass
        except Exception:
            return 93
        return 92
    settings = Settings()
    store = RedisTransactionStore.from_settings(settings)
    try:
        try:
            if not await store._transaction_readiness_probe():
                return 71
            if not await store._session_readiness_probe():
                return 73
            if not await store._refresh_lock_readiness_probe():
                return 74
        except Exception as error:
            if type(error).__name__ == "ConnectionError":
                category = str(error)
                if "CERTIFICATE_VERIFY_FAILED" in category:
                    return 87
                if "Connection refused" in category:
                    return 88
                if "Name or service not known" in category or "Temporary failure in name resolution" in category:
                    return 89
                if "Permission denied" in category:
                    return 90
                if "TLSV1_ALERT" in category:
                    return 91
            return {"NoPermissionError": 81, "AuthenticationError": 82, "ConnectionError": 83, "ResponseError": 84, "TimeoutError": 85}.get(type(error).__name__, 86)
    finally:
        await store.close()
    client = AsyncUpstreamClient(settings)
    cache = AsyncJwksCache(settings, client)
    try:
        try:
            with socket.create_connection(("cognito-idp.ap-south-1.amazonaws.com", 443), timeout=2) as raw:
                with ssl.create_default_context().wrap_socket(raw, server_hostname="cognito-idp.ap-south-1.amazonaws.com"):
                    pass
        except ssl.SSLCertVerificationError:
            return 101
        except OSError:
            return 102
        try:
            snapshot = await cache._fetch_snapshot()
        except Exception as error:
            return {"JwksResponseError": 103, "UpstreamError": 104}.get(type(error).__name__, 105)
        if not snapshot.keys:
            return 106
    finally:
        cache.close()
        await client.close()
    return 0

raise SystemExit(asyncio.run(main()))
PY
chmod 0400 "$temporary/upstream/server.key"
chmod 0444 "$temporary/upstream/ca.crt" "$temporary/upstream/server.crt" "$temporary/upstream/server.py" "$temporary/component-probe.py"
docker run --rm --user 0:0 --mount "type=bind,src=$temporary/upstream,dst=/fixture" \
  --entrypoint /bin/sh "$bff_image" -c \
  'chown 0:0 /fixture /fixture/ca.crt /fixture/server.crt /fixture/server.key /fixture/server.py && chmod 0500 /fixture'

bootstrap_password="$(openssl rand -hex 24)"
migrator_password="$(openssl rand -hex 24)"
runtime_password="$(openssl rand -hex 24)"
redis_password="$(openssl rand -hex 24)"
repository_cipher="$(openssl rand -hex 24)"
client_secret="$(openssl rand -hex 32)"
mkdir -p "$temporary/database" "$temporary/migrator-secret" "$temporary/postgres-client" \
  "$temporary/redis-secret" "$temporary/redis-client-secret" "$temporary/redis-client-tls" "$temporary/client-secret"
printf '%s' "$bootstrap_password" >"$temporary/database/bootstrap_password"
printf '%s' "$migrator_password" >"$temporary/database/migrator_password"
printf '%s' "$runtime_password" >"$temporary/database/runtime_password"
printf '%s' "$migrator_password" >"$temporary/migrator-secret/migrator_password"
printf '%s' "$redis_password" >"$temporary/redis-secret/bff_password"
printf '%s' "$redis_password" >"$temporary/redis-client-secret/bff_password"
printf '%s' "$client_secret" >"$temporary/client-secret/client_secret"
printf 'user default off\nuser portfolio_bff reset on >%s ~reference-bff:production:portfolio:identity:* +ping +get +set +getdel +del +eval +client|setinfo\n' "$redis_password" >"$temporary/redis-secret/users.acl"
cp "$temporary/postgres/ca.crt" "$temporary/postgres-client/ca.crt"
cp "$temporary/redis/ca.crt" "$temporary/redis-client-tls/ca.crt"
chmod 0440 "$temporary"/{database,migrator-secret,redis-secret,redis-client-secret,redis-client-tls,client-secret}/* "$temporary/postgres-client/ca.crt"
chmod 0550 "$temporary"/{database,migrator-secret,redis-secret,redis-client-secret,redis-client-tls,client-secret,postgres-client}
docker run --rm --user 0:0 --mount "type=bind,src=$temporary,dst=/work" --entrypoint /bin/sh "$postgres_image" -c \
  'chown -R 0:10001 /work/database /work/migrator-secret /work/postgres-client; chown -R 0:999 /work/redis-secret; chown -R 0:10002 /work/redis-client-secret /work/redis-client-tls /work/client-secret'

cat >"$temporary/postgres-hba.conf" <<'HBA'
local all identity_bootstrap trust
local all all reject
hostnossl all all 0.0.0.0/0 reject
hostssl all all 0.0.0.0/0 scram-sha-256
HBA
cat >"$temporary/pgbackrest.conf" <<EOF
[global]
repo1-type=posix
repo1-path=/repository
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=$repository_cipher
repo1-retention-full=2
repo1-retention-diff=2
log-level-console=warn
log-level-file=off
archive-timeout=30s

[fixture]
pg1-path=/var/lib/postgresql/18/docker
pg1-socket-path=/run/postgresql
pg1-user=identity_bootstrap
EOF
chmod 0444 "$temporary/postgres-hba.conf" "$temporary/pgbackrest.conf"

docker run --rm --user 0:0 \
  --mount "type=bind,src=$temporary/postgres,dst=/source,readonly" \
  --mount "type=volume,src=$postgres_tls_volume,dst=/destination" \
  --entrypoint /bin/sh "$postgres_image" -c \
  'cp /source/ca.crt /source/server.crt /source/server.key /destination/ && chown 0:999 /destination/* && chmod 0440 /destination/ca.crt /destination/server.crt /destination/server.key'
docker run --rm --user 0:0 \
  --mount "type=bind,src=$temporary/redis,dst=/source,readonly" \
  --mount "type=volume,src=$redis_tls_volume,dst=/destination" \
  --entrypoint /bin/sh "$redis_image" -c \
  'cp /source/ca.crt /source/server.crt /source/server.key /destination/ && chown 0:999 /destination/* && chmod 0440 /destination/ca.crt /destination/server.crt /destination/server.key'
docker run --rm --user 0:0 \
  --mount "type=bind,src=$temporary/pgbackrest.conf,dst=/source/pgbackrest.conf,readonly" \
  --mount "type=volume,src=$pgbackrest_config_volume,dst=/destination" \
  --entrypoint /bin/sh "$pgbackrest_image" -c \
  'cp /source/pgbackrest.conf /destination/pgbackrest.conf && mkdir -p /destination/conf.d && chown -R 2001:2001 /destination && chmod 0600 /destination/pgbackrest.conf && chmod 0700 /destination/conf.d'
docker run --rm --user 0:0 \
  --mount "type=volume,src=$repository_volume,dst=/repository" \
  --mount "type=volume,src=$restore_volume,dst=/restore" \
  --entrypoint /bin/sh "$postgres_image" -c 'chown 2001:2001 /repository /restore && chmod 0700 /repository /restore'
docker run --rm --user 0:0 \
  --mount "type=volume,src=$socket_volume,dst=/socket" \
  --mount "type=volume,src=$spool_volume,dst=/spool" \
  --entrypoint /bin/sh "$postgres_image" -c 'chown 999:999 /socket /spool && chmod 0770 /socket /spool'
docker run --rm --user 0:0 \
  --mount "type=volume,src=$restore_socket_volume,dst=/socket" \
  --mount "type=volume,src=$restore_spool_volume,dst=/spool" \
  --entrypoint /bin/sh "$postgres_image" -c 'chown 999:999 /socket /spool && chmod 0770 /socket /spool'

stage=postgres_start
docker run --detach --name "$postgres" --network "$network" --network-alias postgres \
  --mount "type=volume,src=$data_volume,dst=/var/lib/postgresql" \
  --mount "type=volume,src=$socket_volume,dst=/run/postgresql" \
  --mount "type=volume,src=$spool_volume,dst=/var/spool/pgbackrest" \
  --mount "type=volume,src=$postgres_tls_volume,dst=/run/tls/postgres,readonly" \
  --mount "type=bind,src=$temporary/postgres-client,dst=/run/tls/client,readonly" \
  --mount "type=bind,src=$temporary/database,dst=/run/secrets/database,readonly" \
  --mount "type=bind,src=$temporary/postgres-hba.conf,dst=/run/config/postgres-hba.conf,readonly" \
  --env POSTGRES_DB=identity --env POSTGRES_USER=identity_bootstrap \
  --env POSTGRES_PASSWORD_FILE=/run/secrets/database/bootstrap_password \
  --env 'POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256 --auth-local=trust' \
  "$postgres_image" postgres \
  -c ssl=on -c ssl_cert_file=/run/tls/postgres/server.crt -c ssl_key_file=/run/tls/postgres/server.key \
  -c ssl_ca_file=/run/tls/postgres/ca.crt -c hba_file=/run/config/postgres-hba.conf \
  -c archive_mode=on -c 'archive_command=test ! -f /var/spool/pgbackrest/%f && cp %p /var/spool/pgbackrest/%f.part && mv /var/spool/pgbackrest/%f.part /var/spool/pgbackrest/%f' >/dev/null

stage=postgres_tls_ready
for _ in {1..60}; do
  if docker exec "$postgres" pg_isready --dbname 'host=postgres port=5432 dbname=identity user=identity_bootstrap sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt' >/dev/null 2>&1; then break; fi
  sleep 1
done
if ! docker inspect --format '{{.State.Running}}' "$postgres" 2>/dev/null | grep -qx true; then
  printf 'Identity Docker fixture PostgreSQL did not remain running.\n' >&2
  exit 1
fi
docker exec "$postgres" pg_isready --dbname 'host=postgres port=5432 dbname=identity user=identity_bootstrap sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt' >/dev/null

stage=postgres_roles
if ! docker exec --user 10001:10001 --env PGPASSWORD="$bootstrap_password" --interactive "$postgres" \
  psql 'host=postgres port=5432 dbname=identity user=identity_bootstrap sslmode=verify-full sslrootcert=/run/tls/client/ca.crt' \
  < config/runtime/postgres-roles.sql >/dev/null 2>"$temporary/postgres.stderr"; then
  if grep -Fq 'Permission denied' "$temporary/postgres.stderr"; then
    printf 'Identity PostgreSQL role fixture rejected its secret-file permissions.\n' >&2
  elif grep -Fq 'syntax error' "$temporary/postgres.stderr"; then
    printf 'Identity PostgreSQL role fixture rejected its reviewed SQL syntax.\n' >&2
  elif grep -Fq 'must be member of role' "$temporary/postgres.stderr"; then
    printf 'Identity PostgreSQL role fixture rejected its owner boundary.\n' >&2
  else
    printf 'Identity PostgreSQL role fixture rejected its reviewed bootstrap contract.\n' >&2
  fi
  exit 1
fi
stage=postgres_migration
docker run --rm --network "$network" --user 10001:10001 --read-only --cap-drop ALL \
  --security-opt no-new-privileges --tmpfs /tmp:rw,noexec,nosuid,nodev,size=32m \
  --mount "type=bind,src=$temporary/migrator-secret,dst=/run/secrets/database,readonly" \
  --mount "type=bind,src=$temporary/postgres-client,dst=/run/tls/postgres,readonly" \
  --mount "type=bind,src=$repository_root/config/runtime/identity-launcher.py,dst=/opt/platform/identity-launcher.py,readonly" \
  --entrypoint python "$api_image" /opt/platform/identity-launcher.py migrator \
  >/dev/null 2>"$temporary/migration.stderr"
observed_head="$(docker exec --env PGPASSWORD="$bootstrap_password" "$postgres" \
  psql 'host=postgres port=5432 dbname=identity user=identity_bootstrap sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt' \
  --no-psqlrc --tuples-only --no-align --command 'SELECT version_num FROM identity.alembic_version;')"
[[ "$observed_head" == 0001_initial_identity_schema ]]
stage=postgres_least_privilege
privilege_proof="$(docker exec --env PGPASSWORD="$runtime_password" "$postgres" \
  psql 'host=postgres port=5432 dbname=identity user=identity_service_app sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt' \
  --no-psqlrc --tuples-only --no-align --command \
  "SELECT concat_ws(':', has_schema_privilege('identity_service_app','identity','USAGE'), NOT has_schema_privilege('identity_service_app','identity','CREATE'), has_table_privilege('identity_service_app','identity.profiles','SELECT'), has_table_privilege('identity_service_app','identity.profiles','INSERT'), NOT has_table_privilege('identity_service_app','identity.profiles','DELETE'), NOT has_table_privilege('identity_service_app','identity.profiles','TRUNCATE'), has_column_privilege('identity_service_app','identity.profiles','provider_email','UPDATE'), NOT has_column_privilege('identity_service_app','identity.users','status','UPDATE'));")"
[[ "$privilege_proof" == t:t:t:t:t:t:t:t ]]
if docker exec --env PGPASSWORD="$runtime_password" "$postgres" \
  psql 'host=postgres port=5432 dbname=identity user=identity_service_app sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt' \
  --no-psqlrc --command 'DELETE FROM identity.profiles;' >/dev/null 2>"$temporary/delete.stderr"; then
  printf 'Identity PostgreSQL fixture granted destructive runtime privilege.\n' >&2
  exit 1
fi
if docker exec --env PGPASSWORD="$runtime_password" "$postgres" \
  psql 'host=postgres port=5432 dbname=identity user=identity_service_app sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt' \
  --no-psqlrc --command 'CREATE TABLE identity.forbidden(value text);' >/dev/null 2>"$temporary/ddl.stderr"; then
  printf 'Identity PostgreSQL fixture granted runtime DDL privilege.\n' >&2
  exit 1
fi

stage=pgbackrest_offline_prepare
docker stop "$postgres" >/dev/null
docker run --rm --user 0:0 --mount "type=volume,src=$data_volume,dst=/var/lib/postgresql" \
  --entrypoint /bin/sh "$postgres_image" -c 'chgrp -R 2001 /var/lib/postgresql/18/docker && chmod -R g+rX /var/lib/postgresql/18/docker'
docker run --detach --name "$archiver" --user 2001:2001 \
  --mount "type=volume,src=$data_volume,dst=/var/lib/postgresql,readonly" \
  --mount "type=volume,src=$repository_volume,dst=/repository" \
  --mount "type=volume,src=$pgbackrest_config_volume,dst=/etc/pgbackrest,readonly" \
  --entrypoint /bin/sh "$pgbackrest_image" -c 'sleep 600' >/dev/null
stage=pgbackrest_full_backup
docker exec "$archiver" pgbackrest --stanza=fixture --no-online stanza-create >/dev/null 2>"$temporary/pgbackrest-stanza.stderr"
docker exec "$archiver" pgbackrest --stanza=fixture --no-online --type=full backup >/dev/null 2>"$temporary/pgbackrest-full.stderr"
docker start "$postgres" >/dev/null
for _ in {1..60}; do
  if docker exec "$postgres" pg_isready --dbname 'host=postgres port=5432 dbname=identity user=identity_bootstrap sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt' >/dev/null 2>&1; then break; fi
  sleep 1
done
docker exec --env PGPASSWORD="$bootstrap_password" "$postgres" \
  psql 'host=postgres port=5432 dbname=identity user=identity_bootstrap sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt' \
  --no-psqlrc --command "CREATE TABLE public.platform_restore_sentinel(value text PRIMARY KEY); INSERT INTO public.platform_restore_sentinel VALUES ('published-head-backed-up');" >/dev/null
stage=pgbackrest_diff_backup
docker stop "$postgres" >/dev/null
docker run --rm --user 0:0 --mount "type=volume,src=$data_volume,dst=/var/lib/postgresql" \
  --entrypoint /bin/sh "$postgres_image" -c 'chgrp -R 2001 /var/lib/postgresql/18/docker && chmod -R g+rX /var/lib/postgresql/18/docker'
docker exec "$archiver" pgbackrest --stanza=fixture --no-online --type=diff backup >/dev/null 2>"$temporary/pgbackrest-diff.stderr"
docker stop "$archiver" >/dev/null

stage=pgbackrest_restore
docker run --rm --user 2001:2001 \
  --mount "type=volume,src=$restore_volume,dst=/var/lib/postgresql" \
  --mount "type=volume,src=$repository_volume,dst=/repository,readonly" \
  --mount "type=volume,src=$pgbackrest_config_volume,dst=/etc/pgbackrest,readonly" \
  "$pgbackrest_image" pgbackrest --stanza=fixture --pg1-path=/var/lib/postgresql/18/docker restore >/dev/null
docker run --rm --user 0:0 --mount "type=volume,src=$restore_volume,dst=/var/lib/postgresql" \
  --entrypoint /bin/sh "$postgres_image" -c 'chown -R 999:999 /var/lib/postgresql && chmod 0700 /var/lib/postgresql /var/lib/postgresql/18/docker'
stage=postgres_restore_verify
docker run --detach --name "$restore" --network "$network" \
  --mount "type=volume,src=$restore_volume,dst=/var/lib/postgresql" \
  --mount "type=volume,src=$restore_socket_volume,dst=/run/postgresql" \
  --mount "type=volume,src=$restore_spool_volume,dst=/var/spool/pgbackrest" \
  --mount "type=volume,src=$postgres_tls_volume,dst=/run/tls/postgres,readonly" \
  --mount "type=bind,src=$temporary/postgres-hba.conf,dst=/run/config/postgres-hba.conf,readonly" \
  "$postgres_image" postgres \
  -c ssl=on -c ssl_cert_file=/run/tls/postgres/server.crt -c ssl_key_file=/run/tls/postgres/server.key \
  -c ssl_ca_file=/run/tls/postgres/ca.crt -c hba_file=/run/config/postgres-hba.conf \
  -c archive_mode=off >/dev/null
for _ in {1..60}; do
  if docker exec "$restore" pg_isready --dbname identity --username identity_bootstrap >/dev/null 2>&1; then break; fi
  sleep 1
done
restore_proof="$(docker exec "$restore" psql --username identity_bootstrap --dbname identity \
  --no-psqlrc --tuples-only --no-align --command "SELECT (SELECT version_num FROM identity.alembic_version) || ':' || (SELECT value FROM public.platform_restore_sentinel);")"
[[ "$restore_proof" == '0001_initial_identity_schema:published-head-backed-up' ]]

start_redis() {
  docker run --detach --name "$redis" --network "$network" --network-alias redis \
    --mount "type=volume,src=$redis_tls_volume,dst=/run/tls/redis,readonly" \
    --mount "type=bind,src=$temporary/redis-secret,dst=/run/secrets/redis,readonly" \
    "$redis_image" redis-server --port 0 --tls-port 6379 \
    --tls-cert-file /run/tls/redis/server.crt --tls-key-file /run/tls/redis/server.key \
    --tls-ca-cert-file /run/tls/redis/ca.crt --tls-auth-clients no \
    --aclfile /run/secrets/redis/users.acl --maxmemory 64mb --maxmemory-policy volatile-ttl \
    --appendonly no --save '' >/dev/null
}
stage=redis_tls_acl
start_redis
for _ in {1..30}; do
  if docker exec --env REDISCLI_AUTH="$redis_password" "$redis" redis-cli --tls --user portfolio_bff \
    --sni redis --cacert /run/tls/redis/ca.crt ping 2>/dev/null | grep -qx PONG; then break; fi
  sleep 1
done
redis_cli=(docker exec --env REDISCLI_AUTH="$redis_password" "$redis" redis-cli --tls --user portfolio_bff \
  --sni redis --cacert /run/tls/redis/ca.crt --raw)
namespace=reference-bff:production:portfolio:identity
stage=redis_exact_commands
"${redis_cli[@]}" set "$namespace:set" present NX EX 60 >/dev/null
[[ "$("${redis_cli[@]}" get "$namespace:set")" == present ]]
[[ "$("${redis_cli[@]}" getdel "$namespace:set")" == present ]]
"${redis_cli[@]}" set "$namespace:delete" present EX 60 >/dev/null
"${redis_cli[@]}" set "$namespace:delete" changed XX EX 60 >/dev/null
[[ "$("${redis_cli[@]}" get "$namespace:delete")" == changed ]]
[[ "$("${redis_cli[@]}" del "$namespace:delete")" == 1 ]]
"${redis_cli[@]}" set "$namespace:eval" present EX 60 >/dev/null
[[ "$("${redis_cli[@]}" eval "return redis.call('GET', KEYS[1])" 1 "$namespace:eval")" == present ]]
[[ "$("${redis_cli[@]}" eval "return redis.call('DEL', KEYS[1])" 1 "$namespace:eval")" == 1 ]]
if "${redis_cli[@]}" get forbidden:fixture >"$temporary/redis-denied" 2>&1 && ! grep -Fq NOPERM "$temporary/redis-denied"; then
  printf 'Identity Redis fixture accepted an unauthorized namespace.\n' >&2
  exit 1
fi
grep -Fq NOPERM "$temporary/redis-denied"
if "${redis_cli[@]}" config get '*' >"$temporary/redis-admin-denied" 2>&1 && ! grep -Fq NOPERM "$temporary/redis-admin-denied"; then
  printf 'Identity Redis fixture accepted an administrative command.\n' >&2
  exit 1
fi
grep -Fq NOPERM "$temporary/redis-admin-denied"
stage=redis_expiry
"${redis_cli[@]}" set "$namespace:expiry" present EX 1 >/dev/null
sleep 2
[[ -z "$("${redis_cli[@]}" get "$namespace:expiry")" ]]

stage=published_bff_readiness
docker run --detach --name "$fake" --network "$network" \
  --network-alias auth.rahuly.in --network-alias cognito-idp.ap-south-1.amazonaws.com \
  --network-alias identity.rahuly.in --user 0:0 --read-only --cap-drop ALL --cap-add NET_BIND_SERVICE \
  --security-opt no-new-privileges --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m \
  --mount "type=bind,src=$temporary/upstream,dst=/fixture,readonly" \
  --entrypoint python "$bff_image" /fixture/server.py >/dev/null
sleep 1
if [[ "$(docker inspect --format '{{.State.Running}}' "$fake")" != true ]]; then
  docker logs "$fake" >"$temporary/fake.stderr" 2>&1 || true
  if grep -Fq 'PermissionError' "$temporary/fake.stderr"; then
    printf 'Synthetic provider fixture rejected its private-file permissions.\n' >&2
  elif grep -Fq 'Address already in use' "$temporary/fake.stderr"; then
    printf 'Synthetic provider fixture rejected its isolated listener binding.\n' >&2
  elif grep -Eq 'ImportError|ModuleNotFoundError' "$temporary/fake.stderr"; then
    printf 'Synthetic provider fixture lacked a published runtime dependency.\n' >&2
  elif grep -Fq 'FileNotFoundError' "$temporary/fake.stderr"; then
    printf 'Synthetic provider fixture omitted a generated input file.\n' >&2
  elif grep -Fq 'ssl.SSLError' "$temporary/fake.stderr"; then
    printf 'Synthetic provider fixture rejected its generated TLS identity.\n' >&2
  elif grep -Eq 'AttributeError|TypeError|ValueError' "$temporary/fake.stderr"; then
    printf 'Synthetic provider fixture rejected its generated JWKS analyzer.\n' >&2
  elif grep -Fq 'OSError' "$temporary/fake.stderr"; then
    printf 'Synthetic provider fixture rejected its bounded listener operation.\n' >&2
  else
    printf 'Synthetic provider fixture did not retain its isolated HTTPS listener.\n' >&2
  fi
  exit 1
fi
docker run --detach --name "$bff" --network "$network" --user 10002:10002 --read-only --cap-drop ALL \
  --security-opt no-new-privileges --pids-limit 128 --tmpfs /tmp:rw,noexec,nosuid,nodev,size=32m \
  --mount "type=bind,src=$temporary/client-secret,dst=/run/secrets/client,readonly" \
  --mount "type=bind,src=$temporary/redis-client-secret,dst=/run/secrets/redis,readonly" \
  --mount "type=bind,src=$temporary/redis-client-tls,dst=/run/tls/redis,readonly" \
  --mount "type=bind,src=$repository_root/config/runtime/identity-launcher.py,dst=/opt/platform/identity-launcher.py,readonly" \
  --mount "type=bind,src=$temporary/component-probe.py,dst=/opt/platform/component-probe.py,readonly" \
  --env PLATFORM_COGNITO_ISSUER=https://cognito-idp.ap-south-1.amazonaws.com/ap-south-1_Example123 \
  --env PLATFORM_COGNITO_JWKS_URL=https://cognito-idp.ap-south-1.amazonaws.com/ap-south-1_Example123/.well-known/jwks.json \
  --env PLATFORM_COGNITO_CLIENT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaa \
  --env BFF_ORIGIN=https://rahuly.in --env PORT=8081 \
  --entrypoint python "$bff_image" /opt/platform/identity-launcher.py bff >/dev/null
for _ in {1..60}; do
  if docker exec "$bff" python scripts/healthcheck.py >/dev/null 2>&1; then break; fi
  sleep 1
done
if ! docker exec "$bff" python scripts/healthcheck.py >/dev/null 2>&1; then
  docker logs "$bff" >"$temporary/bff.stderr" 2>&1 || true
  if grep -Fq 'Identity launcher rejected' "$temporary/bff.stderr"; then
    printf 'Immutable BFF fixture rejected its launcher boundary.\n' >&2
  elif grep -Eq 'REDIS|redis' "$temporary/bff.stderr"; then
    printf 'Immutable BFF fixture rejected its Redis startup boundary.\n' >&2
  elif grep -Eq 'COGNITO|AUTHORIZATION|TOKEN|BFF_ORIGIN|ALLOWED_HOSTS|REQUESTED_SCOPES' "$temporary/bff.stderr"; then
    printf 'Immutable BFF fixture rejected its published settings boundary.\n' >&2
  else
    printf 'Immutable BFF fixture did not reach its fixed liveness boundary.\n' >&2
  fi
  exit 1
fi
set +e
docker exec "$bff" python /opt/platform/component-probe.py >/dev/null 2>"$temporary/component.stderr"
component_status=$?
set -e
case "$component_status" in
  0) ;;
  71) printf 'Immutable BFF fixture rejected its Redis transaction readiness.\n' >&2; exit 1 ;;
  72) printf 'Immutable BFF fixture rejected its synthetic JWKS readiness.\n' >&2; exit 1 ;;
  73) printf 'Immutable BFF fixture rejected its Redis session-CAS readiness.\n' >&2; exit 1 ;;
  74) printf 'Immutable BFF fixture rejected its Redis refresh-lock readiness.\n' >&2; exit 1 ;;
  81) printf 'Immutable BFF fixture hit an exact Redis ACL denial.\n' >&2; exit 1 ;;
  82) printf 'Immutable BFF fixture hit a Redis authentication denial.\n' >&2; exit 1 ;;
  83) printf 'Immutable BFF fixture hit a Redis TLS connection denial.\n' >&2; exit 1 ;;
  84) printf 'Immutable BFF fixture hit a Redis protocol response denial.\n' >&2; exit 1 ;;
  85) printf 'Immutable BFF fixture hit a Redis operation timeout.\n' >&2; exit 1 ;;
  86) printf 'Immutable BFF fixture hit an unexpected Redis client failure class.\n' >&2; exit 1 ;;
  87) printf 'Immutable BFF fixture rejected the Redis certificate chain.\n' >&2; exit 1 ;;
  88) printf 'Immutable BFF fixture found no Redis TLS listener.\n' >&2; exit 1 ;;
  89) printf 'Immutable BFF fixture could not resolve the Redis service name.\n' >&2; exit 1 ;;
  90) printf 'Immutable BFF fixture could not read its process-local trust file.\n' >&2; exit 1 ;;
  91) printf 'Immutable BFF fixture received a Redis TLS protocol alert.\n' >&2; exit 1 ;;
  92) printf 'Immutable BFF fixture default trust did not select its process-local bundle.\n' >&2; exit 1 ;;
  93) printf 'Immutable BFF fixture explicit bundle did not validate the Redis server.\n' >&2; exit 1 ;;
  94) printf 'Immutable BFF fixture process-local bundle omitted its private CA.\n' >&2; exit 1 ;;
  101) printf 'Immutable BFF fixture rejected the synthetic provider certificate.\n' >&2; exit 1 ;;
  102) printf 'Immutable BFF fixture could not reach the synthetic provider listener.\n' >&2; exit 1 ;;
  103) printf 'Immutable BFF fixture rejected the synthetic JWKS document.\n' >&2; exit 1 ;;
  104) printf 'Immutable BFF fixture rejected the synthetic provider response boundary.\n' >&2; exit 1 ;;
  105) printf 'Immutable BFF fixture hit an unexpected JWKS client failure class.\n' >&2; exit 1 ;;
  106) printf 'Immutable BFF fixture accepted no synthetic signing key.\n' >&2; exit 1 ;;
  *) printf 'Immutable BFF fixture rejected its isolated component readiness.\n' >&2; exit 1 ;;
esac
docker exec "$bff" python -c 'import http.client; c=http.client.HTTPConnection("127.0.0.1",8081,timeout=3); c.request("GET","/health/ready",headers={"Host":"rahuly.in"}); r=c.getresponse(); r.read(); raise SystemExit(0 if r.status == 200 else 1)'
! docker top "$bff" -eo pid,args | grep -Fq "$client_secret"
! docker top "$bff" -eo pid,args | grep -Fq "$redis_password"
! docker inspect "$bff" | grep -Fq "$client_secret"
! docker inspect "$bff" | grep -Fq "$redis_password"
! docker logs "$bff" 2>&1 | grep -Fq "$client_secret"
! docker logs "$bff" 2>&1 | grep -Fq "$redis_password"
stage=redis_no_persistence_config
mapfile -t redis_arguments < <(docker inspect --format '{{range .Config.Cmd}}{{println .}}{{end}}' "$redis")
argument_pair_exists() {
  local first="$1"
  local second="$2"
  local index
  for ((index = 0; index + 1 < ${#redis_arguments[@]}; index++)); do
    if [[ "${redis_arguments[$index]}" == "$first" && "${redis_arguments[$((index + 1))]}" == "$second" ]]; then
      return 0
    fi
  done
  return 1
}
argument_pair_exists --appendonly no
argument_pair_exists --save ''
stage=redis_no_persistence
"${redis_cli[@]}" set "$namespace:restart" present EX 60 >/dev/null
docker rm -f "$bff" >/dev/null
docker rm -f "$redis" >/dev/null
start_redis
sleep 1
[[ -z "$("${redis_cli[@]}" get "$namespace:restart")" ]]

stage=complete
rm -f -- "$temporary"/*.stderr "$temporary"/redis-*-denied
printf 'Immutable Identity images, launcher, published migration, pgBackRest restore, Redis TLS/ACL, and packed BFF readiness fixtures passed.\n'
