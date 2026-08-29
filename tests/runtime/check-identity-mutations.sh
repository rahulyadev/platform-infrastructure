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
  deploy/ssm/backup-identity.sh
  deploy/ssm/deploy-identity.sh
  deploy/ssm/restore-identity.sh
  deploy/ssm/rollback-identity.sh
  deploy/ssm/verify-identity-release.sh
  deploy/ssm/verify-identity.sh
  infra/live/production/runtime/identity.tf
  infra/live/production/runtime/variables.tf
  infra/modules/identity_production/documents.tf
  infra/modules/identity_production/iam.tf
  infra/modules/identity_production/monitoring.tf
  infra/modules/identity_production/variables.tf
)

for mutation in {1..31}; do
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
    13) sed -i 's/restore_prior_release/skip_prior_restore/g' "$root/deploy/ssm/deploy-identity.sh" ;;
    14) sed -i 's/platform-identity-lifecycle[.]lock/platform-identity-rollback.lock/' "$root/deploy/ssm/rollback-identity.sh" ;;
    15) sed -i 's/IDENTITY_POST_MIGRATION_AUDIT/IDENTITY_OPTIONAL_AUDIT/g' "$root/config/runtime/postgres-roles.sql" ;;
    16) sed -i 's/platform_recovery[.]markers/platform_recovery.unbound/g' "$root/deploy/ssm/restore-identity.sh" ;;
    17) sed -i '/already matches the active generation/d' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    18) sed -i 's/INSERT INTO platform_recovery[.]markers/INSERT INTO platform_recovery.unbound/' "$root/deploy/ssm/backup-identity.sh" ;;
    19) sed -i 's/NOT membership[.]admin_option/membership.admin_option/' "$root/config/runtime/postgres-roles.sql" ;;
    20) sed -i 's/#candidate_inventory\[@\]}" == 2/#candidate_inventory[@]}" == 3/' "$root/deploy/ssm/verify-identity-release.sh" ;;
    21) sed -i '/source_metadata=/d' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    22) sed -i 's/all_directories_equal/all_directories_optional/g' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    23) sed -i '0,/base64gzip[(]/s//base64encode(/' "$root/infra/live/production/runtime/identity.tf" ;;
    24) sed -i 's/ | gzip --decompress//' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    25) sed -i 's/<= 81920/<= 90000/' "$root/infra/modules/identity_production/documents.tf" ;;
    26) sed -i '/^set +x$/a # {{end}}' "$root/deploy/ssm/verify-identity.sh" ;;
    27) sed -i 's/[.]State[.]Running/[.]State[.]Stopped/' "$root/deploy/ssm/verify-identity.sh" ;;
    28) sed -i "s/if ! printf '%s'/if printf '%s'/" "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    29) sed -i 's/mv -Tf -- "$temporary" "$destination"/mv -f -- "$temporary" "$destination"/' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    30) sed -i '/condition     = length(base64encode(local[.]rendered_document_contents/d' "$root/infra/modules/identity_production/documents.tf" ;;
    31) sed -i '/install -m "$mode" \/dev\/null "$temporary"/d' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
  esac
  if python3 "$repository_root/tests/runtime/verify-identity-contract.py" "$root" >"$temporary/output" 2>&1; then
    printf 'Production Identity mutation probe %d was not rejected safely.\n' "$mutation" >&2
    exit 1
  fi
  chmod 0600 "$temporary/output"
  rm -f -- "$temporary/output"
  if ((mutation >= 23)); then
    if IDENTITY_DOCUMENT_POLICY_FIXTURE="$root" \
      bash "$repository_root/tests/policy/check-production-identity.sh" >"$temporary/output" 2>&1; then
      printf 'Production Identity policy mutation probe %d was not rejected safely.\n' "$mutation" >&2
      exit 1
    fi
    chmod 0600 "$temporary/output"
    rm -f -- "$temporary/output"
  fi
done
printf 'Production Identity independent mutation probes passed.\n'
