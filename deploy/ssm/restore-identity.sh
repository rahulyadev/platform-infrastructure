#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
set +x

readonly recovery_target="${SSM_recoveryTarget:-immediate}"
readonly restore_root=/var/lib/platform/identity-restore-rehearsal
[[ "$recovery_target" == immediate || "$recovery_target" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
[[ ! -e "$restore_root" ]]
install -d -m 0700 "$restore_root"
if [[ "$recovery_target" == immediate ]]; then
  docker compose --file /opt/platform/identity/current/compose.yml --project-name identity-production run --rm --no-deps \
    --volume "$restore_root:/restore" pgbackrest pgbackrest --stanza=identity --pg1-path=/restore/data --delta restore
else
  docker compose --file /opt/platform/identity/current/compose.yml --project-name identity-production run --rm --no-deps \
    --volume "$restore_root:/restore" pgbackrest pgbackrest --stanza=identity --pg1-path=/restore/data --type=time --target="$recovery_target" --target-action=promote restore
fi
test -f "$restore_root/data/PG_VERSION"
printf 'Identity isolated restore rehearsal materialized successfully.\n'
