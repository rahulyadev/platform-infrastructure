#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
set +x

readonly current=/opt/platform/identity/current
readonly previous=/opt/platform/identity/previous
[[ -L "$previous" ]]
rollback_target="$(readlink -f -- "$previous")"
[[ -f "$rollback_target/compose.yml" && -f "$rollback_target/release.env" ]]
ln -sfn -- "$rollback_target" "$current.next"
mv -Tf -- "$current.next" "$current"
install -m 0600 "$rollback_target/release.env" /etc/platform/identity/release.env
systemctl restart identity-stack.service
/usr/local/libexec/platform/identity-health-verify
printf 'Identity rollback restored the retained prior release.\n'
