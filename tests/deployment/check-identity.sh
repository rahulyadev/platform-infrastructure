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

for script in deploy/ssm/*identity*.sh; do bash -n "$script"; done
bash -n deploy/ssm/configure-identity-runtime.sh.tftpl
python3 tests/runtime/verify-identity-contract.py . >/dev/null

grep -Fq 'set +x' deploy/ssm/configure-identity-runtime.sh.tftpl
grep -Fq 'aws secretsmanager get-secret-value' deploy/ssm/configure-identity-runtime.sh.tftpl
! grep -Eq -- '--secret-string|--value[[:space:]]+.*secret|set -x' deploy/ssm/*identity*.sh*
grep -Fq 'sha256sum --check --status' deploy/ssm/configure-identity-runtime.sh.tftpl
grep -Fq 'get-login-password --region ap-south-1 | docker login --username AWS --password-stdin' deploy/ssm/deploy-identity.sh
grep -Fq "docker image inspect --format '{{.Architecture}}/{{.Os}}'" deploy/ssm/deploy-identity.sh
[[ "$(grep -Fc 'run --rm migrator' deploy/ssm/deploy-identity.sh)" == 1 ]]
! grep -Fq 'migrator check' deploy/ssm/deploy-identity.sh
grep -Fq 'identity-health-verify' deploy/ssm/deploy-identity.sh deploy/ssm/rollback-identity.sh
grep -Fq 'live_schema=' deploy/ssm/rollback-identity.sh
grep -Fq 'mktemp -d /var/lib/platform/identity-restore-rehearsal.XXXXXXXX' deploy/ssm/restore-identity.sh
grep -Fq 'IdentityWalArchiveStale' deploy/ssm/verify-identity.sh
grep -Fq 'Dimensions=[{Name=InstanceId' deploy/ssm/verify-identity.sh deploy/ssm/backup-identity.sh deploy/ssm/deploy-identity.sh
! grep -Eq 'tofu apply|aws ssm send-command|ssh |scp ' deploy/ssm/*identity*.sh*

make_configuration_root() {
  local root="$1"
  install -d -m 0700 "$root" "$root/stage" "$root/active" "$root/active/generations/old" "$root/active/generations/new"
  printf 'new-binary\n' >"$root/stage/global-binary"
  printf 'new-unit\n' >"$root/stage/global-unit"
  printf 'new-generation\n' >"$root/stage/generation"
  printf 'old-binary\n' >"$root/active/global-binary"
  printf 'old-unit\n' >"$root/active/global-unit"
  printf 'disabled\n' >"$root/active/enablement"
  ln -s generations/old "$root/active/generation-link"
}

assert_configuration_old() {
  local root="$1"
  grep -Fxq old-binary "$root/active/global-binary"
  grep -Fxq old-unit "$root/active/global-unit"
  grep -Fxq disabled "$root/active/enablement"
  [[ "$(readlink -- "$root/active/generation-link")" == generations/old ]]
  ! find "$root/active" -maxdepth 1 -name '*.next' -print -quit | grep -q .
}

for boundary in global-binary global-unit generation-link enablement; do
  root="$temporary/config-$boundary"
  make_configuration_root "$root"
  if PLATFORM_IDENTITY_CONFIGURATION_TEST_ROOT="$root" PLATFORM_IDENTITY_FAIL_AT="$boundary" \
    PLATFORM_IDENTITY_FIXTURE_WORKLOAD_ACTIVE=false \
    bash deploy/ssm/configure-identity-runtime.sh.tftpl --transaction-fixture >"$temporary/config.out" 2>&1; then
    printf 'Identity configuration failure fixture did not reject a post-write boundary.\n' >&2
    exit 1
  fi
  assert_configuration_old "$root"
done

root="$temporary/config-active"
make_configuration_root "$root"
if PLATFORM_IDENTITY_CONFIGURATION_TEST_ROOT="$root" PLATFORM_IDENTITY_FAIL_AT=none \
  PLATFORM_IDENTITY_FIXTURE_WORKLOAD_ACTIVE=true \
  bash deploy/ssm/configure-identity-runtime.sh.tftpl --transaction-fixture >"$temporary/config.out" 2>&1; then
  printf 'Identity configuration fixture accepted an active host-global upgrade.\n' >&2
  exit 1
fi
assert_configuration_old "$root"

root="$temporary/config-success"
make_configuration_root "$root"
PLATFORM_IDENTITY_CONFIGURATION_TEST_ROOT="$root" PLATFORM_IDENTITY_FAIL_AT=none \
  PLATFORM_IDENTITY_FIXTURE_WORKLOAD_ACTIVE=false \
  bash deploy/ssm/configure-identity-runtime.sh.tftpl --transaction-fixture >/dev/null
grep -Fxq new-binary "$root/active/global-binary"
grep -Fxq new-unit "$root/active/global-unit"
grep -Fxq enabled "$root/active/enablement"
[[ "$(readlink -- "$root/active/generation-link")" == generations/new ]]
before="$(stat -c '%i:%Y' "$root/active/global-binary" "$root/active/global-unit" "$root/active/enablement" "$root/active/generation-link")"
PLATFORM_IDENTITY_CONFIGURATION_TEST_ROOT="$root" PLATFORM_IDENTITY_FAIL_AT=none \
  PLATFORM_IDENTITY_FIXTURE_WORKLOAD_ACTIVE=true \
  bash deploy/ssm/configure-identity-runtime.sh.tftpl --transaction-fixture >/dev/null
after="$(stat -c '%i:%Y' "$root/active/global-binary" "$root/active/global-unit" "$root/active/enablement" "$root/active/generation-link")"
[[ "$before" == "$after" ]]

make_activation_root() {
  local root="$1" current_name="$2" previous_name="$3"
  install -d -m 0700 "$root"
  install -d -m 0755 "$root/run/lock" "$root/opt/platform/identity/releases" \
    "$root/etc/platform/identity" "$root/etc/nginx/conf.d" "$root/usr/local/libexec/platform" "$root/bin"
  for name in old older new candidate; do
    install -d -m 0755 "$root/opt/platform/identity/releases/$name"
    printf 'IDENTITY_SCHEMA_HEAD=0001_initial_identity_schema\nIDENTITY_RELEASE_ID=%s\n' "$name" >"$root/opt/platform/identity/releases/$name/release.env"
    chmod 0600 "$root/opt/platform/identity/releases/$name/release.env"
    printf 'services: {}\n' >"$root/opt/platform/identity/releases/$name/compose.yml"
    chmod 0644 "$root/opt/platform/identity/releases/$name/compose.yml"
    : >"$root/opt/platform/identity/releases/$name/healthy"
  done
  ln -s "$root/opt/platform/identity/releases/$current_name" "$root/opt/platform/identity/current"
  ln -s "$root/opt/platform/identity/releases/$previous_name" "$root/opt/platform/identity/previous"
  install -m 0600 "$root/opt/platform/identity/releases/$current_name/release.env" "$root/etc/platform/identity/release.env"
  printf 'nginx=old\n' >"$root/etc/nginx/conf.d/identity-runtime.conf"
  printf 'nginx=new\n' >"$root/etc/platform/identity/identity-runtime.conf.staged"
  printf 'active\n' >"$root/service-state"
  readlink -f -- "$root/opt/platform/identity/current" >"$root/service-target"

  cat >"$root/bin/systemctl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
root="$PLATFORM_IDENTITY_LIFECYCLE_TEST_ROOT"
case "$1" in
  is-active) grep -Fxq active "$root/service-state" ;;
  reload) : ;;
  restart) printf 'active\n' >"$root/service-state"; readlink -f -- "$root/opt/platform/identity/current" >"$root/service-target" ;;
  stop) printf 'inactive\n' >"$root/service-state"; : >"$root/service-target" ;;
  *) exit 1 ;;
esac
SH
  cat >"$root/bin/nginx" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
root="$PLATFORM_IDENTITY_LIFECYCLE_TEST_ROOT"
[[ "$1" == -t ]]
grep -Eq '^nginx=(old|new)$' "$root/etc/nginx/conf.d/identity-runtime.conf"
SH
  cat >"$root/usr/local/libexec/platform/identity-verify-release" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
root="$PLATFORM_IDENTITY_LIFECYCLE_TEST_ROOT"
target="${1:-$(readlink -f -- "$root/opt/platform/identity/current")}"
[[ "$target" == "$root/opt/platform/identity/releases/"* && -d "$target" && ! -L "$target" ]]
[[ -f "$target/release.env" && -f "$target/compose.yml" && -f "$target/healthy" ]]
SH
  cat >"$root/usr/local/libexec/platform/identity-health-verify" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
root="$PLATFORM_IDENTITY_LIFECYCLE_TEST_ROOT"
[[ "$(<"$root/service-state")" == active ]]
[[ "$(<"$root/service-target")" == "$(readlink -f -- "$root/opt/platform/identity/current")" ]]
[[ -f "$(<"$root/service-target")/healthy" ]]
SH
  chmod 0755 "$root/bin/systemctl" "$root/bin/nginx" \
    "$root/usr/local/libexec/platform/identity-verify-release" "$root/usr/local/libexec/platform/identity-health-verify"
}

assert_restored() {
  local root="$1" current_name="$2" previous_name="$3"
  [[ "$(readlink -f -- "$root/opt/platform/identity/current")" == "$root/opt/platform/identity/releases/$current_name" ]]
  [[ "$(readlink -f -- "$root/opt/platform/identity/previous")" == "$root/opt/platform/identity/releases/$previous_name" ]]
  cmp -s "$root/etc/platform/identity/release.env" "$root/opt/platform/identity/releases/$current_name/release.env"
  grep -Fxq nginx=old "$root/etc/nginx/conf.d/identity-runtime.conf"
  [[ "$(<"$root/service-state")" == active ]]
  [[ "$(<"$root/service-target")" == "$root/opt/platform/identity/releases/$current_name" ]]
  ! find "$root" -name '*.next' -print -quit | grep -q .
}

deploy_boundaries=(current_link release_environment nginx_configuration nginx_validation nginx_reload service_restart release_verification health_verification previous_promotion)
for boundary in "${deploy_boundaries[@]}"; do
  root="$temporary/deploy-$boundary"
  make_activation_root "$root" old older
  if PATH="$root/bin:$PATH" PLATFORM_IDENTITY_LIFECYCLE_TEST_ROOT="$root" \
    PLATFORM_IDENTITY_FIXTURE_RELEASE="$root/opt/platform/identity/releases/candidate" PLATFORM_IDENTITY_FAIL_AT="$boundary" \
    bash deploy/ssm/deploy-identity.sh --activation-fixture >"$temporary/deploy.out" 2>&1; then
    printf 'Identity deployment failure fixture did not reject a post-activation boundary.\n' >&2
    exit 1
  fi
  assert_restored "$root" old older
done

root="$temporary/deploy-success"
make_activation_root "$root" old older
PATH="$root/bin:$PATH" PLATFORM_IDENTITY_LIFECYCLE_TEST_ROOT="$root" \
  PLATFORM_IDENTITY_FIXTURE_RELEASE="$root/opt/platform/identity/releases/candidate" PLATFORM_IDENTITY_FAIL_AT=none \
  bash deploy/ssm/deploy-identity.sh --activation-fixture >/dev/null
[[ "$(readlink -f -- "$root/opt/platform/identity/current")" == "$root/opt/platform/identity/releases/candidate" ]]
[[ "$(readlink -f -- "$root/opt/platform/identity/previous")" == "$root/opt/platform/identity/releases/old" ]]
[[ "$(<"$root/service-target")" == "$root/opt/platform/identity/releases/candidate" ]]

rollback_boundaries=(current_link release_environment nginx_validation nginx_reload service_restart release_verification health_verification previous_promotion)
for boundary in "${rollback_boundaries[@]}"; do
  root="$temporary/rollback-$boundary"
  make_activation_root "$root" new old
  if PATH="$root/bin:$PATH" PLATFORM_IDENTITY_LIFECYCLE_TEST_ROOT="$root" \
    PLATFORM_IDENTITY_FIXTURE_SCHEMA=0001_initial_identity_schema PLATFORM_IDENTITY_FAIL_AT="$boundary" \
    bash deploy/ssm/rollback-identity.sh --activation-fixture >"$temporary/rollback.out" 2>&1; then
    printf 'Identity rollback failure fixture did not reject a post-activation boundary.\n' >&2
    exit 1
  fi
  assert_restored "$root" new old
done

root="$temporary/rollback-success"
make_activation_root "$root" new old
PATH="$root/bin:$PATH" PLATFORM_IDENTITY_LIFECYCLE_TEST_ROOT="$root" \
  PLATFORM_IDENTITY_FIXTURE_SCHEMA=0001_initial_identity_schema PLATFORM_IDENTITY_FAIL_AT=none \
  bash deploy/ssm/rollback-identity.sh --activation-fixture >/dev/null
[[ "$(readlink -f -- "$root/opt/platform/identity/current")" == "$root/opt/platform/identity/releases/old" ]]
[[ "$(readlink -f -- "$root/opt/platform/identity/previous")" == "$root/opt/platform/identity/releases/new" ]]
[[ "$(<"$root/service-target")" == "$root/opt/platform/identity/releases/old" ]]

metadata_root="$temporary/recovery-metadata"
install -d -m 0700 "$metadata_root"
write_metadata() {
  local destination="$1" marker="$2" created="$3" started="$4" stopped="$5" label="$6"
  printf '{"backup_label":"%s","backup_started_at":"%s","backup_stopped_at":"%s","backup_type":"full","marker":"%s","marker_created_at":"%s","schema_head":"0001_initial_identity_schema","version":1}\n' \
    "$label" "$started" "$stopped" "$marker" "$created" >"$destination"
  chmod 0600 "$destination"
}
write_metadata "$metadata_root/identity-backup-20260101T000100Z.json" \
  11111111111111111111111111111111 2026-01-01T00:00:00Z 2026-01-01T00:00:30Z 2026-01-01T00:01:00Z 20260101-000100F
write_metadata "$metadata_root/identity-backup-20260101T001100Z.json" \
  22222222222222222222222222222222 2026-01-01T00:10:00Z 2026-01-01T00:10:30Z 2026-01-01T00:11:00Z 20260101-001100F
PLATFORM_IDENTITY_RECOVERY_METADATA_ROOT="$metadata_root" SSM_recoveryTarget=immediate \
  bash deploy/ssm/restore-identity.sh --metadata-fixture >/dev/null
PLATFORM_IDENTITY_RECOVERY_METADATA_ROOT="$metadata_root" SSM_recoveryTarget=2026-01-01T00:05:00Z \
  bash deploy/ssm/restore-identity.sh --metadata-fixture >/dev/null
if PLATFORM_IDENTITY_RECOVERY_METADATA_ROOT="$metadata_root" SSM_recoveryTarget=2025-12-31T23:59:59Z \
  bash deploy/ssm/restore-identity.sh --metadata-fixture >"$temporary/metadata.out" 2>&1; then
  printf 'Identity recovery metadata fixture accepted a target without an eligible marker.\n' >&2
  exit 1
fi

bad_metadata="$temporary/recovery-bad"
install -d -m 0700 "$bad_metadata"
write_metadata "$bad_metadata/identity-backup-20260101T000100Z.json" \
  not-a-marker 2026-01-01T00:00:00Z 2026-01-01T00:00:30Z 2026-01-01T00:01:00Z 20260101-000100F
if PLATFORM_IDENTITY_RECOVERY_METADATA_ROOT="$bad_metadata" SSM_recoveryTarget=immediate \
  bash deploy/ssm/restore-identity.sh --metadata-fixture >"$temporary/metadata.out" 2>&1; then
  printf 'Identity recovery metadata fixture accepted a mismatched marker.\n' >&2
  exit 1
fi
rm -f -- "$bad_metadata"/*
write_metadata "$bad_metadata/identity-backup-20260101T000100Z.json" \
  33333333333333333333333333333333 2026-01-01T00:00:45Z 2026-01-01T00:00:30Z 2026-01-01T00:01:00Z 20260101-000100F
if PLATFORM_IDENTITY_RECOVERY_METADATA_ROOT="$bad_metadata" SSM_recoveryTarget=immediate \
  bash deploy/ssm/restore-identity.sh --metadata-fixture >"$temporary/metadata.out" 2>&1; then
  printf 'Identity recovery metadata fixture accepted a stale marker lineage.\n' >&2
  exit 1
fi
rm -f -- "$bad_metadata"/*
if PLATFORM_IDENTITY_RECOVERY_METADATA_ROOT="$bad_metadata" SSM_recoveryTarget=immediate \
  bash deploy/ssm/restore-identity.sh --metadata-fixture >"$temporary/metadata.out" 2>&1; then
  printf 'Identity recovery metadata fixture accepted a missing marker.\n' >&2
  exit 1
fi

rm -f -- "$temporary"/*.out
printf 'Production Identity deployment and executable lifecycle-recovery checks passed.\n'
