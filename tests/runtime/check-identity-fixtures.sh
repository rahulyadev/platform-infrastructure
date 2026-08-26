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

prefix="platform-p3i4-fixture-$$"
network="$prefix"
postgres="$prefix-postgres"
restore="$prefix-restore"
archiver="$prefix-archiver"
redis="$prefix-redis"
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

fixture_failed() {
  printf 'Identity Docker fixture failed safely at stage=%s.\n' "$stage" >&2
}

cleanup() {
  docker rm -f "$postgres" "$restore" "$archiver" "$redis" >/dev/null 2>&1 || true
  docker volume rm "$data_volume" "$socket_volume" "$spool_volume" "$repository_volume" "$restore_volume" "$postgres_tls_volume" "$redis_tls_volume" "$pgbackrest_config_volume" "$restore_socket_volume" "$restore_spool_volume" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  chmod -R u+rwx "$temporary" >/dev/null 2>&1 || true
  rm -rf -- "$temporary"
}
trap fixture_failed ERR
trap cleanup EXIT

postgres_image='postgres@sha256:a02db8cac496f15b094798a38254f14d6e00741f709360e5e00bb6668ea31636'
redis_image='redis@sha256:5fa2edb1e408fa8235e6db8fab01d1afaaae96c9403ba67b70feceb8661e8621'
pgbackrest_image='woblerr/pgbackrest@sha256:c5bc798fdbee479fc23fd419221755f8f0a97756f3a830ec7cc0c6678067e846'

docker network create --internal "$network" >/dev/null
for volume in "$data_volume" "$socket_volume" "$spool_volume" "$repository_volume" "$restore_volume" "$postgres_tls_volume" "$redis_tls_volume" "$pgbackrest_config_volume" "$restore_socket_volume" "$restore_spool_volume"; do
  docker volume create "$volume" >/dev/null
done

make_tls_identity() {
  local identity="$1"
  local directory="$temporary/$identity"
  mkdir -p "$directory"
  openssl genrsa -out "$directory/ca.key" 2048 >/dev/null 2>&1
  openssl req -x509 -new -key "$directory/ca.key" -days 1 -subj "/CN=$identity-fixture-ca" -out "$directory/ca.crt" >/dev/null 2>&1
  openssl genrsa -out "$directory/server.key" 2048 >/dev/null 2>&1
  openssl req -new -key "$directory/server.key" -subj "/CN=$identity" -out "$directory/server.csr" >/dev/null 2>&1
  printf 'subjectAltName=DNS:%s,DNS:restore\nextendedKeyUsage=serverAuth\n' "$identity" >"$directory/server.ext"
  openssl x509 -req -in "$directory/server.csr" -CA "$directory/ca.crt" -CAkey "$directory/ca.key" -CAcreateserial -days 1 -extfile "$directory/server.ext" -out "$directory/server.crt" >/dev/null 2>&1
  openssl genrsa -out "$directory/client.key" 2048 >/dev/null 2>&1
  openssl req -new -key "$directory/client.key" -subj "/CN=fixture-client" -out "$directory/client.csr" >/dev/null 2>&1
  printf 'extendedKeyUsage=clientAuth\n' >"$directory/client.ext"
  openssl x509 -req -in "$directory/client.csr" -CA "$directory/ca.crt" -CAkey "$directory/ca.key" -CAcreateserial -days 1 -extfile "$directory/client.ext" -out "$directory/client.crt" >/dev/null 2>&1
  chmod 0444 "$directory/ca.crt" "$directory/server.crt" "$directory/client.crt"
  chmod 0400 "$directory/server.key" "$directory/client.key"
}

make_tls_identity postgres
make_tls_identity redis

bootstrap_password="$(openssl rand -hex 24)"
migrator_password="$(openssl rand -hex 24)"
runtime_password="$(openssl rand -hex 24)"
redis_password="$(openssl rand -hex 24)"
repository_cipher="$(openssl rand -hex 24)"
mkdir -p "$temporary/database" "$temporary/postgres-secret" "$temporary/redis-secret"
printf '%s' "$bootstrap_password" >"$temporary/postgres-secret/bootstrap_password"
printf '%s' "$migrator_password" >"$temporary/database/migrator_password"
printf '%s' "$runtime_password" >"$temporary/database/runtime_password"
printf 'user default off\nuser portfolio_bff on >%s ~portfolio:identity:bff:* +@read +@write -@dangerous\n' "$redis_password" >"$temporary/redis-secret/users.acl"
chmod 0444 "$temporary"/{database,postgres-secret,redis-secret}/*
chmod 0555 "$temporary/database" "$temporary/redis-secret"

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
  'cp /source/ca.crt /source/server.crt /source/server.key /destination/ && chown 999:999 /destination/* && chmod 0444 /destination/ca.crt /destination/server.crt && chmod 0600 /destination/server.key'
docker run --rm --user 0:0 \
  --mount "type=bind,src=$temporary/redis,dst=/source,readonly" \
  --mount "type=volume,src=$redis_tls_volume,dst=/destination" \
  --entrypoint /bin/sh "$redis_image" -c \
  'cp /source/ca.crt /source/server.crt /source/server.key /source/client.crt /source/client.key /destination/ && chown 999:999 /destination/* && chmod 0444 /destination/ca.crt /destination/server.crt /destination/client.crt && chmod 0600 /destination/server.key /destination/client.key'
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
  --mount "type=bind,src=$temporary/database,dst=/run/secrets/database,readonly" \
  --mount "type=bind,src=$temporary/postgres-secret,dst=/run/secrets/postgres,readonly" \
  --mount "type=bind,src=$temporary/postgres-hba.conf,dst=/run/config/postgres-hba.conf,readonly" \
  --env POSTGRES_DB=identity --env POSTGRES_USER=identity_bootstrap \
  --env POSTGRES_PASSWORD_FILE=/run/secrets/postgres/bootstrap_password \
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
docker exec --env PGPASSWORD="$bootstrap_password" --interactive "$postgres" \
  psql 'host=postgres port=5432 dbname=identity user=identity_bootstrap sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt' \
  < config/runtime/postgres-roles.sql >/dev/null 2>"$temporary/postgres.stderr"
stage=postgres_migration
docker exec --env PGPASSWORD="$migrator_password" "$postgres" \
  psql 'host=postgres port=5432 dbname=identity user=identity_migrator sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt' \
  --no-psqlrc --set ON_ERROR_STOP=1 --command \
  "SET ROLE identity_owner; CREATE TABLE schema_migrations(version text PRIMARY KEY); INSERT INTO schema_migrations VALUES ('head'); CREATE TABLE profiles(id bigint PRIMARY KEY, email text NOT NULL); INSERT INTO profiles VALUES (1, 'fixture.invalid');" \
  >/dev/null 2>"$temporary/migration.stderr"
stage=postgres_least_privilege
runtime_count="$(docker exec --env PGPASSWORD="$runtime_password" "$postgres" \
  psql 'host=postgres port=5432 dbname=identity user=identity_runtime sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt' \
  --no-psqlrc --tuples-only --no-align --command 'SELECT count(*) FROM profiles;')"
[[ "$runtime_count" == 1 ]]
if docker exec --env PGPASSWORD="$runtime_password" "$postgres" \
  psql 'host=postgres port=5432 dbname=identity user=identity_runtime sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt' \
  --no-psqlrc --command 'DELETE FROM profiles;' >/dev/null 2>"$temporary/delete.stderr"; then
  printf 'Identity PostgreSQL fixture granted destructive runtime privilege.\n' >&2
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
docker exec --env PGPASSWORD="$migrator_password" "$postgres" \
  psql 'host=postgres port=5432 dbname=identity user=identity_migrator sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt' \
  --no-psqlrc --command "SET ROLE identity_owner; INSERT INTO profiles VALUES (2, 'restore.invalid');" >/dev/null
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
docker run --detach --name "$restore" --network "$network" --network-alias restore \
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
  if docker exec "$restore" pg_isready --dbname 'host=restore port=5432 dbname=identity user=identity_runtime sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt' >/dev/null 2>&1; then break; fi
  sleep 1
done
restore_proof="$(docker exec --env PGPASSWORD="$runtime_password" "$restore" \
  psql 'host=restore port=5432 dbname=identity user=identity_runtime sslmode=verify-full sslrootcert=/run/tls/postgres/ca.crt' \
  --no-psqlrc --tuples-only --no-align --command "SELECT count(*) || ':' || (SELECT version FROM schema_migrations) FROM profiles;")"
[[ "$restore_proof" == '2:head' ]]

start_redis() {
  docker run --detach --name "$redis" --network "$network" --network-alias redis \
    --mount "type=volume,src=$redis_tls_volume,dst=/run/tls/redis,readonly" \
    --mount "type=bind,src=$temporary/redis-secret,dst=/run/secrets/redis,readonly" \
    "$redis_image" redis-server --port 0 --tls-port 6379 \
    --tls-cert-file /run/tls/redis/server.crt --tls-key-file /run/tls/redis/server.key \
    --tls-ca-cert-file /run/tls/redis/ca.crt --tls-auth-clients yes \
    --aclfile /run/secrets/redis/users.acl --maxmemory 64mb --maxmemory-policy volatile-ttl \
    --appendonly no --save '' >/dev/null
}
stage=redis_tls_acl
start_redis
for _ in {1..30}; do
  if docker exec --env REDISCLI_AUTH="$redis_password" "$redis" redis-cli --tls --user portfolio_bff \
    --cacert /run/tls/redis/ca.crt --cert /run/tls/redis/client.crt --key /run/tls/redis/client.key ping 2>/dev/null | grep -qx PONG; then break; fi
  sleep 1
done
redis_cli=(docker exec --env REDISCLI_AUTH="$redis_password" "$redis" redis-cli --tls --user portfolio_bff \
  --cacert /run/tls/redis/ca.crt --cert /run/tls/redis/client.crt --key /run/tls/redis/client.key --raw)
stage=redis_expiry
"${redis_cli[@]}" set portfolio:identity:bff:fixture present EX 1 >/dev/null
sleep 2
[[ "$("${redis_cli[@]}" exists portfolio:identity:bff:fixture)" == 0 ]]
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
docker rm -f "$redis" >/dev/null
start_redis
sleep 1
[[ "$("${redis_cli[@]}" dbsize)" == 0 ]]

stage=complete
rm -f -- "$temporary"/*.stderr
printf 'Identity PostgreSQL TLS/role/migration/pgBackRest restore and Redis TLS/ACL/expiry/no-persistence fixtures passed.\n'
