#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
set +x

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
temporary="$(mktemp -d)"
chmod 0700 "$temporary"
trap 'rm -rf -- "$temporary"' EXIT
files=(
  config/nginx/identity-runtime.conf.tftpl
  config/runtime/identity-compose.yml.tftpl
  config/runtime/identity-launcher.py
  config/runtime/postgres-roles.sql
  deploy/ssm/configure-identity-runtime.sh.tftpl
  deploy/ssm/deploy-identity.sh
  deploy/ssm/restore-identity.sh
  deploy/ssm/rollback-identity.sh
  deploy/ssm/verify-identity-release.sh
  deploy/ssm/verify-identity.sh
  infra/live/production/runtime/variables.tf
  infra/modules/identity_production/documents.tf
  infra/modules/identity_production/iam.tf
  infra/modules/identity_production/monitoring.tf
  infra/modules/identity_production/variables.tf
)

for mutation in {1..12}; do
  root="$temporary/$mutation"
  install -d -m 0700 "$root"
  for file in "${files[@]}"; do
    install -D -m 0600 "$repository_root/$file" "$root/$file"
  done
  case "$mutation" in
    1) sed -i 's/API_UID = 10001/API_UID = 65532/' "$root/config/runtime/identity-launcher.py" ;;
    2) sed -i 's/127.0.0.1:8082:8081/127.0.0.1:8082:8080/' "$root/config/runtime/identity-compose.yml.tftpl" ;;
    3) sed -i 's/AUTH_DOMAIN = "auth.rahuly.in"/AUTH_DOMAIN = "other.invalid"/' "$root/config/runtime/identity-launcher.py" ;;
    4) sed -i 's#"scripts/migrate_local.py"#"migrate check"#' "$root/config/runtime/identity-launcher.py" ;;
    5) sed -i 's/reference-bff:production:portfolio:identity/unsafe:namespace/' "$root/config/runtime/identity-launcher.py" ;;
    6) sed -i '0,/- "no"/s//- "yes"/' "$root/config/runtime/identity-compose.yml.tftpl" ;;
    7) sed -i 's/__IDENTITY_API_REPOSITORY_URL__/__IDENTITY_BFF_REPOSITORY_URL__/' "$root/deploy/ssm/deploy-identity.sh" ;;
    8) sed -i 's/"backup": {"repository_cipher"}/"backup": {"repository_cipher", "extra"}/' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    9) sed -i '/alarm_actions/d' "$root/infra/modules/identity_production/monitoring.tf" ;;
    10) sed -i 's#https://identity.${base_domain}#https://${base_domain}#' "$root/config/nginx/identity-runtime.conf.tftpl" ;;
    11) sed -i '/live_schema=/d' "$root/deploy/ssm/rollback-identity.sh" ;;
    12) sed -i 's/== 13/== 12/' "$root/deploy/ssm/verify-identity-release.sh" ;;
  esac
  if python3 "$repository_root/tests/runtime/verify-identity-contract.py" "$root" >"$temporary/output" 2>&1; then
    printf 'Production Identity mutation probe %d was not rejected safely.\n' "$mutation" >&2
    exit 1
  fi
  chmod 0600 "$temporary/output"
  rm -f -- "$temporary/output"
done
printf 'Production Identity independent mutation probes passed.\n'
