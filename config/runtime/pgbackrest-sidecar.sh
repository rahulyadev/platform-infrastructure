#!/bin/sh
set -eu
umask 077
set +x

repository_cipher_path=/run/secrets/backup/repository_cipher
[ -f "$repository_cipher_path" ] && [ ! -L "$repository_cipher_path" ]
[ "$(/usr/bin/stat -c '%a:%u:%g' "$repository_cipher_path")" = 440:0:65532 ]
repository_cipher="$(/bin/cat "$repository_cipher_path")"
[ -n "$repository_cipher" ]
export PGBACKREST_REPO1_CIPHER_PASS="$repository_cipher"
unset repository_cipher

if [ "$#" -gt 0 ]; then
  exec /usr/bin/pgbackrest "$@"
fi

stanza="${PGBACKREST_STANZA:-identity}"
archive_input_root=/var/lib/postgresql/18/docker/pg_wal/platform-spool

while :; do
  found=false
  for wal_file in /var/spool/pgbackrest/*; do
    [ -f "$wal_file" ] || continue
    case "$wal_file" in *.part) continue ;; esac
    found=true
    wal_name="${wal_file##*/}"
    archive_input="$archive_input_root/$wal_name"
    [ -f "$archive_input" ] && [ ! -L "$archive_input" ]
    [ "$(/usr/bin/stat -c '%d:%i' "$archive_input")" = "$(/usr/bin/stat -c '%d:%i' "$wal_file")" ]
    /usr/bin/pgbackrest --stanza="$stanza" --no-archive-async archive-push "$archive_input"
    rm -f -- "$wal_file"
    touch /var/spool/pgbackrest/.last-archive-success
  done
  if [ "$found" = false ]; then
    sleep 5
  fi
done
