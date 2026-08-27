#!/bin/sh
set -eu
umask 077
stanza="${PGBACKREST_STANZA:-identity}"
pgbackrest --stanza="$stanza" stanza-create

while :; do
  found=false
  for wal_file in /var/spool/pgbackrest/*; do
    [ -f "$wal_file" ] || continue
    case "$wal_file" in *.part) continue ;; esac
    found=true
    pgbackrest --stanza="$stanza" archive-push "$wal_file"
    rm -f -- "$wal_file"
    touch /var/spool/pgbackrest/.last-archive-success
  done
  if [ "$found" = false ]; then
    sleep 5
  fi
done
