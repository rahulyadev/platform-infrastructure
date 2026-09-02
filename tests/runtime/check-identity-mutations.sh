#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
set +x

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
temporary="$(mktemp -d)"
chmod 0700 "$temporary"
trap 'rm -rf -- "$temporary"' EXIT

rendered_configure="$temporary/configure-identity-runtime.sh"
sed 's/\$\${/${/g' "$repository_root/deploy/ssm/configure-identity-runtime.sh.tftpl" >"$rendered_configure"
chmod 0700 "$rendered_configure"

run_staging_fixture() {
  local fixture_root="$1"
  PLATFORM_IDENTITY_STAGING_PARENT_TEST_ROOT="$fixture_root" \
    bash "$rendered_configure" --active-staging-parent-fixture
}

assert_staging_fixture_failure() {
  local fixture_root="$1" removed_parent="${2:-}"
  local -a environment=("PLATFORM_IDENTITY_STAGING_PARENT_TEST_ROOT=$fixture_root")
  if [[ -n "$removed_parent" ]]; then
    environment+=("PLATFORM_IDENTITY_STAGING_PARENT_REMOVE_BEFORE_WRITE=$removed_parent")
  fi
  if env "${environment[@]}" bash "$rendered_configure" --active-staging-parent-fixture >"$temporary/output" 2>&1; then
    printf 'Production Identity active-staging negative fixture was not rejected safely.\n' >&2
    exit 1
  fi
  grep -Fxq 'Identity active-staging parent fixture failed safely.' "$temporary/output"
  [[ ! -e "$fixture_root/active" && ! -L "$fixture_root/active" ]]
  rm -f -- "$temporary/output"
}

staging_success="$temporary/staging-success"
install -d -m 0700 "$staging_success"
run_staging_fixture "$staging_success" >"$temporary/output"
grep -Fxq 'Identity active-staging parent fixture completed.' "$temporary/output"
python3 - "$staging_success/active" <<'PY'
import hashlib
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
uid, gid = os.getuid(), os.getgid()
parents = {
    "etc/systemd/system": 0o755,
    "usr/local/libexec/platform": 0o755,
}
files = {
    "etc/systemd/system/identity-stack.service": 0o644,
    "usr/local/libexec/platform/identity-verify-release": 0o755,
    "usr/local/libexec/platform/identity-health-verify": 0o755,
    "usr/local/libexec/platform/pgbackrest-sidecar": 0o755,
    "etc/systemd/system/docker.service": 0o644,
}
for relative, mode in parents.items():
    path = root / relative
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or path.is_symlink() or (stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid) != (mode, uid, gid):
        raise SystemExit(1)
for relative, mode in files.items():
    path = root / relative
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or path.is_symlink() or (stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid) != (mode, uid, gid):
        raise SystemExit(1)
    if hashlib.sha256(path.read_bytes()).hexdigest() != "1ce34317ffb240600f311bc23275840f6310262d0771d2b719e112bd78641d85":
        raise SystemExit(1)
PY
find "$staging_success/active" -printf '%P:%y:%m:%U:%G\n' | LC_ALL=C sort >"$temporary/staging-first.inventory"
find "$staging_success/active" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum >>"$temporary/staging-first.inventory"
run_staging_fixture "$staging_success" >"$temporary/output"
find "$staging_success/active" -printf '%P:%y:%m:%U:%G\n' | LC_ALL=C sort >"$temporary/staging-second.inventory"
find "$staging_success/active" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum >>"$temporary/staging-second.inventory"
cmp -s "$temporary/staging-first.inventory" "$temporary/staging-second.inventory"

for removed_parent in etc/systemd/system usr/local/libexec/platform; do
  staging_missing="$temporary/staging-missing-${removed_parent//\//-}"
  install -d -m 0700 "$staging_missing"
  assert_staging_fixture_failure "$staging_missing" "$removed_parent"
done

staging_wrong="$temporary/staging-wrong"
install -d -m 0700 "$staging_wrong"
install -d -m 0755 "$staging_wrong/active"
install -d -m 0755 "$staging_wrong/active/etc/systemd/system"
chmod 0750 "$staging_wrong/active/etc/systemd/system"
assert_staging_fixture_failure "$staging_wrong"

staging_symlink="$temporary/staging-symlink"
install -d -m 0700 "$staging_symlink"
install -d -m 0755 "$staging_symlink/active"
install -d -m 0755 "$staging_symlink/active/etc/systemd" "$staging_symlink/link-target"
ln -s "$staging_symlink/link-target" "$staging_symlink/active/etc/systemd/system"
assert_staging_fixture_failure "$staging_symlink"
printf 'Production Identity isolated active-staging filesystem fixture passed.\n'

prepare_unit_verification_fixture() {
  local fixture_root="$1"
  install -d -m 0700 \
    "$fixture_root/active/etc/systemd/system" \
    "$fixture_root/active/usr/local/bin" \
    "$fixture_root/active/usr/local/lib/docker/cli-plugins" \
    "$fixture_root/active/usr/local/libexec/platform" \
    "$fixture_root/canonical" \
    "$fixture_root/verification"
  install -m 0644 "$repository_root/config/runtime/docker.service" \
    "$fixture_root/active/etc/systemd/system/docker.service"
  install -m 0644 "$repository_root/config/runtime/docker.service" \
    "$fixture_root/canonical/docker.service"
  install -m 0644 "$repository_root/config/runtime/identity-stack.service" \
    "$fixture_root/active/etc/systemd/system/identity-stack.service"
  install -m 0644 "$repository_root/config/runtime/identity-stack.service" \
    "$fixture_root/canonical/identity-stack.service"
  for executable in \
    active/usr/local/bin/dockerd \
    active/usr/local/lib/docker/cli-plugins/docker-compose \
    active/usr/local/libexec/platform/identity-verify-release; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture_root/$executable"
    chmod 0755 "$fixture_root/$executable"
  done
}

run_unit_verification_fixture() {
  local fixture_root="$1" docker_payload identity_payload
  docker_payload="$(gzip --no-name --stdout "$fixture_root/canonical/docker.service" | base64 -w0)"
  identity_payload="$(gzip --no-name --stdout "$fixture_root/canonical/identity-stack.service" | base64 -w0)"
  PLATFORM_IDENTITY_UNIT_VERIFICATION_TEST_ROOT="$fixture_root" \
  PLATFORM_IDENTITY_DOCKER_UNIT_B64GZIP="$docker_payload" \
  PLATFORM_IDENTITY_STACK_UNIT_B64GZIP="$identity_payload" \
    bash "$rendered_configure" --unit-verification-fixture
}

assert_unit_verification_failure() {
  local fixture_root="$1"
  if run_unit_verification_fixture "$fixture_root" >"$temporary/output" 2>&1; then
    printf 'Production Identity staged-unit negative fixture was not rejected safely.\n' >&2
    exit 1
  fi
  [[ ! -e "$fixture_root/verification" && ! -L "$fixture_root/verification" ]]
  [[ ! -s "$temporary/output" ]]
  rm -f -- "$temporary/output"
}

unit_success="$temporary/unit-success"
prepare_unit_verification_fixture "$unit_success"
run_unit_verification_fixture "$unit_success" >"$temporary/output"
grep -Fxq 'Identity staged-unit verification fixture completed.' "$temporary/output"
[[ ! -e "$unit_success/verification" && ! -L "$unit_success/verification" ]]
rm -f -- "$temporary/output"

managed_executables=(
  usr/local/bin/dockerd
  usr/local/libexec/platform/identity-verify-release
  usr/local/lib/docker/cli-plugins/docker-compose
  usr/local/lib/docker/cli-plugins/docker-compose
)
for index in "${!managed_executables[@]}"; do
  for defect in missing non-executable symlink; do
    unit_negative="$temporary/unit-${index}-${defect}"
    prepare_unit_verification_fixture "$unit_negative"
    executable="$unit_negative/active/${managed_executables[$index]}"
    case "$defect" in
      missing) rm -f -- "$executable" ;;
      non-executable) chmod 0644 "$executable" ;;
      symlink)
        rm -f -- "$executable"
        ln -s /bin/true "$executable"
        ;;
    esac
    assert_unit_verification_failure "$unit_negative"
  done
done

unit_live_only="$temporary/unit-live-only"
prepare_unit_verification_fixture "$unit_live_only"
sed -i 's#ExecStartPre=/usr/local/libexec/platform/identity-verify-release#ExecStartPre=/bin/true#' \
  "$unit_live_only/active/etc/systemd/system/identity-stack.service" \
  "$unit_live_only/canonical/identity-stack.service"
assert_unit_verification_failure "$unit_live_only"

unit_wrong_directive="$temporary/unit-wrong-directive"
prepare_unit_verification_fixture "$unit_wrong_directive"
sed -i 's#ExecStartPre=/usr/local/libexec/platform/identity-verify-release#ExecCondition=/usr/local/libexec/platform/identity-verify-release#' \
  "$unit_wrong_directive/active/etc/systemd/system/identity-stack.service" \
  "$unit_wrong_directive/canonical/identity-stack.service"
assert_unit_verification_failure "$unit_wrong_directive"

unit_extra="$temporary/unit-extra-replacement"
prepare_unit_verification_fixture "$unit_extra"
printf 'ExecStart=/usr/local/bin/dockerd --duplicate\n' >>"$unit_extra/active/etc/systemd/system/docker.service"
printf 'ExecStart=/usr/local/bin/dockerd --duplicate\n' >>"$unit_extra/canonical/docker.service"
assert_unit_verification_failure "$unit_extra"

unit_changed_argument="$temporary/unit-changed-argument"
prepare_unit_verification_fixture "$unit_changed_argument"
sed -i 's/--remove-orphans/--remove-orphans --changed/' \
  "$unit_changed_argument/active/etc/systemd/system/identity-stack.service"
assert_unit_verification_failure "$unit_changed_argument"

unit_altered_canonical="$temporary/unit-altered-canonical"
prepare_unit_verification_fixture "$unit_altered_canonical"
printf '# altered canonical unit\n' >>"$unit_altered_canonical/canonical/docker.service"
assert_unit_verification_failure "$unit_altered_canonical"
printf 'Production Identity real systemd staged-unit fixture passed with paired cleanup and negative proofs.\n'

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
  infra/modules/identity_production/github_oidc.tf
  infra/modules/identity_production/iam.tf
  infra/modules/identity_production/monitoring.tf
  infra/modules/identity_production/variables.tf
  tests/runtime/check-identity-fixtures.sh
)

for mutation in {1..108}; do
  root="$temporary/$mutation"
  install -d -m 0700 "$root"
  for file in "${files[@]}"; do
    install -D -m 0600 "$repository_root/$file" "$root/$file"
  done
  if ! python3 "$repository_root/tests/runtime/verify-identity-contract.py" "$root" >"$temporary/output" 2>&1; then
    printf 'Production Identity pristine mutation fixture %d failed.\n' "$mutation" >&2
    exit 1
  fi
  if ((mutation >= 23 && mutation <= 31 || mutation >= 87 && mutation <= 108)); then
    IDENTITY_DOCUMENT_POLICY_FIXTURE="$root" \
      bash "$repository_root/tests/policy/check-production-identity.sh" >"$temporary/output" 2>&1
  elif ((mutation >= 32 && mutation <= 51)); then
    IDENTITY_OIDC_POLICY_FIXTURE="$root/infra/modules/identity_production/github_oidc.tf" \
      bash "$repository_root/tests/policy/check-production-identity.sh" >"$temporary/output" 2>&1
  elif ((mutation >= 52 && mutation <= 76)); then
    IDENTITY_PUBLISHER_POLICY_FIXTURE="$root/infra/modules/identity_production/iam.tf" \
      bash "$repository_root/tests/policy/check-production-identity.sh" >"$temporary/output" 2>&1
  fi
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
    77) sed -i 's/[$][{]each[.]key[}]/MON-SAT/' "$root/infra/modules/identity_production/documents.tf" ;;
    78) sed -i 's/[$][{]each[.]key[}]/MON,TUE/' "$root/infra/modules/identity_production/documents.tf" ;;
    79) sed -i '/^[[:space:]]*MON = /d' "$root/infra/modules/identity_production/documents.tf" ;;
    80) sed -i 's/^[[:space:]]*TUE = /    MON = /' "$root/infra/modules/identity_production/documents.tf" ;;
    81) sed -i 's/cron(0\/30 [*] [*] [*] ? [*])/rate(30 minutes)/' "$root/infra/modules/identity_production/documents.tf" ;;
    82) sed -i '/resource "aws_ssm_association" "verify_identity"/,/^}/ {/apply_only_at_cron_interval/d;}' "$root/infra/modules/identity_production/documents.tf" ;;
    83) sed -i '/^  "etc\/systemd\/system:0755"$/d' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    84) sed -i '/^  "usr\/local\/libexec\/platform:0755"$/d' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    85) sed -i '/for specification in "[$][$]{manual_active_staging_parent_specs\[@\]}"; do/a\    [[ "$relative_parent" == etc/systemd/system ]] || continue' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    86) sed -i '$a resource "aws_ssm_association" "extra_identity" {}' "$root/infra/modules/identity_production/documents.tf" ;;
    87) sed -i '/^  "etc\/systemd\/system:0755"$/d' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    88) sed -i '/^  "usr\/local\/libexec\/platform:0755"$/d' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    89) sed -i '/for specification in "[$][$]{manual_active_staging_parent_specs\[@\]}"; do/a\    [[ "$relative_parent" == etc/systemd/system ]] || continue' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    90)
      python3 - "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
creation = 'prepare_manual_active_staging_parents "$work_root/active" 0 0\n'
first_write = 'write_b64gzip \'${systemd_unit_b64gzip}\' "$work_root/active/etc/systemd/system/identity-stack.service" 0644\n'
if source.count(creation) != 1 or source.count(first_write) != 1:
    raise SystemExit("Identity active-staging ordering mutation setup failed safely.")
source = source.replace(creation, "", 1).replace(first_write, first_write + creation, 1)
path.write_text(source, encoding="utf-8")
PY
      ;;
    91) sed -i '0,/! -L "$parent" && /s///' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    92) sed -i 's/prepare_manual_active_staging_parents "$work_root\/active" 0 0/prepare_manual_active_staging_parents "$work_root\/active" 1 0/' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    93) sed -i 's/prepare_manual_active_staging_parents "$work_root\/active" 0 0/prepare_manual_active_staging_parents "$work_root\/active" 0 1/' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    94) sed -i '0,/"etc\/systemd\/system:0755"/s//"etc\/systemd\/system:0775"/' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    95) sed -i '/prepare_manual_active_staging_parents "$work_root\/active" 0 0/a\write_b64gzip '\''${systemd_unit_b64gzip}'\'' "$work_root/active/opt/undeclared/member" 0644' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    96) sed -i '/^  "usr\/local\/libexec\/platform:0755"$/a\  "opt/unused:0755"' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    97) sed -i 's/--recursive-errors=yes/--recursive-errors=no/' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    98) sed -i 's#2>"$verification_root/systemd.stderr"#2>"$verification_root/systemd.stderr" || true#' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    99) sed -i 's#("docker.service", "ExecStart", "/#("docker.service", "ExecStartPre", "/#' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    100) sed -i 's#/usr/local/bin/dockerd#/usr/local/bin/docker#' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    101) sed -i '/("docker.service", "ExecStart",/a\    ("docker.service", "ExecStart", "/usr/local/bin/dockerd"),' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    102) sed -i '/if staged_bytes != canonical_units\[unit_name\]/,+1d' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    103) sed -i '/if reversed_bytes != originals\[unit_name\]/,+1d' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    104) sed -i 's/if replacement_count != 4:/if replacement_count != 3:/' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    105) sed -i '/or path.is_symlink()/d' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    106) sed -i 's/exact_regular(executable, 0o755)/exact_regular(executable, 0o644)/' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    107) sed -i '/systemd-analyze --recursive-errors=yes verify/,/2>"$verification_root\/systemd.stderr"/d' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    108) sed -i 's/or transformed.count(prefix) != 1/or transformed.count(prefix) < 1/' "$root/deploy/ssm/configure-identity-runtime.sh.tftpl" ;;
    3[2-9]|4[0-9]|5[01])
      python3 - "$root/infra/modules/identity_production/github_oidc.tf" "$mutation" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
subject = 'repo:${var.github_owner}@${var.github_owner_id}/${var.github_repository}@${var.github_repository_id}:environment:${var.github_environment}'
condition = '''    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:%s"
      values   = [%s]
    }
'''
principal = '''    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }
'''
mutations = {
    32: (subject, 'repo:${var.github_owner}/${var.github_repository}:environment:${var.github_environment}'),
    33: (subject, subject.replace('@${var.github_owner_id}', '')),
    34: (subject, subject.replace('@${var.github_repository_id}', '')),
    35: (subject, 'repo:${var.github_owner}@${var.github_repository_id}/${var.github_repository}@${var.github_owner_id}:environment:${var.github_environment}'),
    36: (subject, subject.replace('${var.github_environment}', '*')),
    37: ('test     = "StringEquals"', 'test     = "StringLike"'),
    38: (subject, subject.replace('${var.github_environment}', 'staging')),
    39: (subject, subject.replace(':environment:${var.github_environment}', '')),
    40: (condition % ('aud', '"sts.amazonaws.com"'), ''),
    41: (condition % ('repository_owner_id', 'tostring(var.github_owner_id)'), ''),
    42: (condition % ('repository_id', 'tostring(var.github_repository_id)'), ''),
    43: ('values   = [local.github_subject]', 'values   = [local.github_subject, "repo:other/other:environment:production"]'),
    44: ('identifiers = [var.github_oidc_provider_arn]', 'identifiers = [var.github_oidc_provider_arn, "arn:example:other"]'),
    45: (principal, principal + principal),
    46: ('  statement {', '  statement { effect = "Allow" actions = ["sts:AssumeRoleWithWebIdentity"] }\n  statement {'),
    47: ('  github_subject = "' + subject + '"', '  # github_subject = "' + subject + '"\n  github_subject = "untrusted"'),
    48: ('type        = "Federated"', 'type        = "AWS"'),
    49: ('actions = ["sts:AssumeRoleWithWebIdentity"]', 'actions = ["sts:AssumeRole"]'),
    50: ('values   = [tostring(var.github_owner_id)]', 'values   = [tostring(var.github_repository_id)]'),
    51: ('values   = ["sts.amazonaws.com"]', 'values   = ["other.invalid"]'),
}
old, new = mutations[int(sys.argv[2])]
if old not in source or old == new:
    raise SystemExit("Identity trust mutation setup failed safely.")
path.write_text(source.replace(old, new, 1), encoding="utf-8")
PY
      ;;
    *)
      python3 - "$root/infra/modules/identity_production/iam.tf" "$mutation" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
publisher, separator, host = source.partition('data "aws_iam_policy_document" "host_identity_runtime"')
start = publisher.index('  statement {\n    sid    = "PublishIdentityImages"')
end = publisher.index('  statement {\n    sid    = "RunReviewedIdentityDocuments"')
statement = publisher[start:end]
manifest = '      "ecr:BatchGetImage",\n'
scope = 'resources = [for repository in aws_ecr_repository.identity : repository.arn]'
binding = '''resource "aws_iam_role_policy" "github_identity_deployer" {
  name   = "${var.name_prefix}-identity-deployer"
  role   = aws_iam_role.github_identity_deployer.id
  policy = data.aws_iam_policy_document.github_identity_deployer.json
}
'''
mutations = {
    52: (manifest, ''),
    53: (manifest, '      # "ecr:BatchGetImage",\n'),
    54: (manifest, manifest + '      "ecr:DescribeImages",\n'),
    55: (manifest, manifest + '      "ecr:GetDownloadUrlForLayer",\n'),
    56: (manifest, manifest + '      "ecr:BatchDeleteImage",\n'),
    57: (manifest, manifest + '      "ecr:DeleteRepository",\n'),
    58: (manifest, '      "ecr:*",\n'),
    59: (scope, 'resources = ["*"]'),
    60: (scope, 'resources = concat([for repository in aws_ecr_repository.identity : repository.arn], ["arn:aws:ecr:ap-south-1:000000000000:repository/other"])'),
    61: (scope, 'resources = ["arn:aws:ecr:ap-south-1:000000000000:repository/platform-infrastructure-production-identity-api"]'),
    62: (scope, 'resources = ["arn:aws:ecr:us-east-1:000000000000:repository/platform-infrastructure-production-identity-api"]'),
    63: (statement, statement + '  statement { actions = ["ecr:DescribeRepositories"] resources = ["*"] }\n'),
    64: ('role   = aws_iam_role.github_identity_deployer.id', 'role   = var.instance_role_name'),
    65: ('policy = data.aws_iam_policy_document.github_identity_deployer.json', 'policy = data.aws_iam_policy_document.host_identity_runtime.json'),
    66: (statement, statement.replace('effect = "Allow"', 'effect = "Deny"')),
    67: ('sid    = "PublishIdentityImages"', 'sid    = "OtherPublisher"'),
    68: (manifest, manifest + manifest),
    69: (statement, ''),
    70: ('resources = ["*"]', 'resources = [for repository in aws_ecr_repository.identity : repository.arn]'),
    71: (manifest, manifest + '      "ssm:SendCommand",\n'),
    72: (scope, 'resources = [aws_ecr_repository.identity["${var.name_prefix}-identity-api"].arn]'),
    73: (binding, binding + binding.replace('"github_identity_deployer"', '"additional_publisher"')),
    74: (statement, '/*\n' + statement + '*/\n'),
    75: (manifest, '      /* "ecr:BatchGetImage", */\n'),
    76: (statement, statement + statement),
}
old, new = mutations[int(sys.argv[2])]
if not separator or old not in publisher or old == new:
    raise SystemExit("Identity publisher mutation setup failed safely.")
path.write_text(publisher.replace(old, new, 1) + separator + host, encoding="utf-8")
PY
      ;;
  esac
  result=0
  if python3 "$repository_root/tests/runtime/verify-identity-contract.py" "$root" >"$temporary/output" 2>&1; then
    printf 'Production Identity mutation probe %d was not rejected safely.\n' "$mutation" >&2
    exit 1
  else
    result=$?
  fi
  [[ "$result" == 1 && "$(wc -l <"$temporary/output")" == 1 ]]
  grep -Fxq 'Production Identity executable contract check failed safely.' "$temporary/output"
  chmod 0600 "$temporary/output"
  rm -f -- "$temporary/output"
  if ((mutation >= 23 && mutation <= 31 || mutation >= 87 && mutation <= 108)); then
    if IDENTITY_DOCUMENT_POLICY_FIXTURE="$root" \
      bash "$repository_root/tests/policy/check-production-identity.sh" >"$temporary/output" 2>&1; then
      printf 'Production Identity policy mutation probe %d was not rejected safely.\n' "$mutation" >&2
      exit 1
    fi
    chmod 0600 "$temporary/output"
    rm -f -- "$temporary/output"
  elif ((mutation >= 32 && mutation <= 51)); then
    if IDENTITY_OIDC_POLICY_FIXTURE="$root/infra/modules/identity_production/github_oidc.tf" \
      bash "$repository_root/tests/policy/check-production-identity.sh" >"$temporary/output" 2>&1; then
      printf 'Production Identity OIDC policy mutation probe %d was not rejected safely.\n' "$mutation" >&2
      exit 1
    fi
    grep -Fxq 'PRODUCTION IDENTITY POLICY FAILURE: Identity OIDC trust must retain the sole ID-bearing environment subject and exact independent guards' "$temporary/output"
    rm -f -- "$temporary/output"
  elif ((mutation >= 52 && mutation <= 76)); then
    result=0
    if IDENTITY_PUBLISHER_POLICY_FIXTURE="$root/infra/modules/identity_production/iam.tf" \
      bash "$repository_root/tests/policy/check-production-identity.sh" >"$temporary/output" 2>&1; then
      printf 'Production Identity publisher policy mutation probe %d was not rejected safely.\n' "$mutation" >&2
      exit 1
    else
      result=$?
    fi
    [[ "$result" == 1 && "$(wc -l <"$temporary/output")" == 1 ]]
    grep -Fxq 'PRODUCTION IDENTITY POLICY FAILURE: Identity publisher must retain exactly six scoped ECR actions and the complete policy binding' "$temporary/output"
    rm -f -- "$temporary/output"
  fi
done
printf 'Production Identity independent mutation probes passed: 108 pristine controls and 108 rejections; 31 document, 20 OIDC and 25 publisher cases also rejected by the independent policy gate.\n'
