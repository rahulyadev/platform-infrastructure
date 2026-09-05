#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd -- "$repository_root"
failures=0

fail() {
  printf 'PRODUCTION IDENTITY POLICY FAILURE: %s\n' "$1" >&2
  failures=$((failures + 1))
}

require_fixed() {
  grep -Fq -- "$2" "$1" || fail "$3"
}

require_count() {
  local actual
  actual="$(grep -Ec -- "$2" "$3" || true)"
  [[ "$actual" == "$1" ]] || fail "$4"
}

reject() {
  if grep -Eq -- "$1" "$2"; then
    fail "$3"
  fi
}

require_text_count() {
  local actual
  actual="$(grep -Ec -- "$2" <<<"$3" || true)"
  [[ "$actual" == "$1" ]] || fail "$4"
}

extract_braced_block() {
  local pattern="$1"

  awk -v pattern="$pattern" '
    !capturing && $0 ~ pattern { capturing = 1 }
    capturing {
      print
      line = $0
      opens = gsub(/\{/, "{", line)
      line = $0
      closes = gsub(/\}/, "}", line)
      depth += opens - closes
      if (depth == 0) {
        exit
      }
    }
  '
}

extract_bracketed_list() {
  local pattern="$1"

  awk -v pattern="$pattern" '
    !capturing && $0 ~ pattern { capturing = 1 }
    capturing {
      print
      line = $0
      opens = gsub(/\[/, "[", line)
      line = $0
      closes = gsub(/\]/, "]", line)
      depth += opens - closes
      if (depth == 0) {
        exit
      }
    }
  '
}

check_identity_oidc_trust() {
  if ! python3 - "$1" <<'PY'
import pathlib
import re
import sys

# Match the entire operative token stream, not comment/string search hits.
# Quoted HCL templates remain single tokens; whitespace/comments are inert.
def tokens(source):
    scanner = re.compile(r'\s+|\#[^\n]*|//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[A-Za-z_][A-Za-z_0-9.-]*|.', re.S)
    return [token for token in scanner.findall(source)
            if not token.isspace() and not token.startswith(('#', '//', '/*'))]

expected = '''
locals {
  github_subject = "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repository}@${var.github_repository_id}:environment:${var.github_environment}"
}
data "aws_iam_policy_document" "github_assume" {
  statement {
    effect = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }
'''
for claim, expression in (
    ('aud', '"sts.amazonaws.com"'),
    ('sub', 'local.github_subject'),
    ('repository_owner_id', 'tostring(var.github_owner_id)'),
    ('repository_id', 'tostring(var.github_repository_id)'),
):
    expected += ('condition { test = "StringEquals" variable = '
                 f'"token.actions.githubusercontent.com:{claim}" values = [{expression}] }}\n')
expected += '''
  }
}
resource "aws_iam_role" "github_identity_deployer" {
  name = "${var.name_prefix}-identity-deployer"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
  tags = var.tags
}
'''
try:
    valid = tokens(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')) == tokens(expected)
except (OSError, UnicodeError):
    valid = False
raise SystemExit(0 if valid else 1)
PY
  then
    fail "Identity OIDC trust must retain the sole ID-bearing environment subject and exact independent guards"
  fi
}

check_identity_publisher() {
  if ! python3 - "$1" <<'PY'
import pathlib
import re
import sys

def tokens(source):
    scanner = re.compile(r'\s+|\#[^\n]*|//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[A-Za-z_][A-Za-z_0-9.-]*|.', re.S)
    return [token for token in scanner.findall(source)
            if not token.isspace() and not token.startswith(('#', '//', '/*'))]

# The complete publisher document and binding are operative source. The host's
# separate pull permission and comment-only decoys cannot satisfy this contract.
expected = '''
data "aws_iam_policy_document" "github_identity_deployer" {
  statement {
    sid = "EcrLogin"
    effect = "Allow"
    actions = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "PublishIdentityImages"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [for repository in aws_ecr_repository.identity : repository.arn]
  }
  statement {
    sid = "RunReviewedIdentityDocuments"
    effect = "Allow"
    actions = ["ssm:SendCommand",]
    resources = concat(
      ["arn:aws:ec2:${var.aws_region}:${var.expected_account_id}:instance/${var.instance_id}"],
      [for key in ["deploy", "verify", "rollback"] : aws_ssm_document.identity[key].arn],
    )
  }
  statement {
    sid = "ObserveIdentityCommands"
    effect = "Allow"
    actions = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations",]
    resources = ["*"]
  }
}
resource "aws_iam_role_policy" "github_identity_deployer" {
  name = "${var.name_prefix}-identity-deployer"
  role = aws_iam_role.github_identity_deployer.id
  policy = data.aws_iam_policy_document.github_identity_deployer.json
}
'''
try:
    actual, required = tokens(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')), tokens(expected)
    valid = actual[:len(required)] == required
    cursor = len(required)
    for kind, resource_type in (('data', 'aws_iam_policy_document'), ('resource', 'aws_iam_role_policy')):
        valid = valid and actual[cursor:cursor + 4] == [kind, f'"{resource_type}"', '"host_identity_runtime"', '{']
        cursor += 4
        depth = 1
        while depth and cursor < len(actual):
            depth += (actual[cursor] == '{') - (actual[cursor] == '}')
            cursor += 1
        valid = valid and depth == 0
    valid = valid and cursor == len(actual)
except (OSError, UnicodeError):
    valid = False
raise SystemExit(0 if valid else 1)
PY
  then
    fail "Identity publisher must retain exactly six scoped ECR actions and the complete policy binding"
  fi
}

check_manual_active_staging_parents() {
  if ! python3 - "$1" <<'PY'
import pathlib
import re
import sys

try:
    source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
    manifest = re.search(
        r'^readonly -a manual_active_staging_parent_specs=\(\n(?P<body>(?:  "[^\n]+"\n)+)\)$',
        source,
        re.MULTILINE,
    )
    declared = [] if manifest is None else re.findall(
        r'^  "([a-z0-9][a-z0-9/-]*):(0[0-7]{3})"$',
        manifest.group("body"),
        re.MULTILINE,
    )
    writes = re.findall(
        r'^write_b64gzip \'\$\{([a-z_]+)_b64gzip\}\' "\$work_root/active/([^\"]+)" (0[0-7]{3})$',
        source,
        re.MULTILINE,
    )
    expected_declared = [
        ("etc/systemd/system", "0755"),
        ("usr/local/libexec/platform", "0755"),
    ]
    expected_writes = [
        ("systemd_unit", "etc/systemd/system/identity-stack.service", "0644"),
        ("verify_release", "usr/local/libexec/platform/identity-verify-release", "0755"),
        ("health_verify", "usr/local/libexec/platform/identity-health-verify", "0755"),
        ("pgbackrest_sidecar", "usr/local/libexec/platform/pgbackrest-sidecar", "0755"),
        ("docker_service", "etc/systemd/system/docker.service", "0644"),
    ]
    derived = sorted({str(pathlib.PurePosixPath(path).parent) for _, path, _ in writes})
    function_start = source.index("prepare_manual_active_staging_parents() {")
    function_end = source.index("\n}\n", function_start) + 2
    function = source[function_start:function_end]
    production_call = 'prepare_manual_active_staging_parents "$work_root/active" 0 0'
    call_index = source.index(production_call)
    write_indexes = [
        source.index(f"write_b64gzip '${{{payload}_b64gzip}}' \"$work_root/active/{path}\" {mode}")
        for payload, path, mode in expected_writes
    ]
    exact_check = '[[ -d "$parent" && ! -L "$parent" && "$(stat -c \'%a:%u:%g\' "$parent")" == "$expected_metadata" ]]'
    valid = (
        manifest is not None
        and declared == expected_declared
        and writes == expected_writes
        and derived == sorted(path for path, _ in declared)
        and function.count('for specification in "$${manual_active_staging_parent_specs[@]}"; do') == 1
        and function.count('install -d -m "$mode" -o "$expected_uid" -g "$expected_gid" "$parent"') == 1
        and function.count(exact_check) == 2
        and function.count('[[ "$mode" == 0755 ]]') == 1
        and 'continue' not in function
        and '|| true' not in function
        and source.count(production_call) == 1
        and not re.search(r'install -d[^\n]*"\$work_root/active/(?:etc/systemd/system|usr/local/libexec/platform)"', source)
        and manifest.start() < function_start < call_index < min(write_indexes)
        and write_indexes == sorted(write_indexes)
    )
except (OSError, UnicodeError, ValueError):
    valid = False
raise SystemExit(0 if valid else 1)
PY
  then
    fail "Identity manual active-staging writes must retain the exact manifest-derived parent contract"
  fi
}

check_staged_unit_verification() {
  if ! python3 - "$1" <<'PY'
import ast
import pathlib
import re
import sys

try:
    source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
    start = source.index("verify_staged_units() (")
    end = source.index(
        '\n)\n\nif [[ "$*" == --unit-verification-fixture ]]', start
    ) + 2
    verifier = source[start:end]
    match = re.search(
        r"^mapping = (?P<value>\(\n(?:    \([^\n]+\),\n)+\))$",
        verifier,
        re.MULTILINE,
    )
    mapping = None if match is None else ast.literal_eval(match.group("value"))
    expected = (
        ("docker.service", "ExecStart", "/usr/local/bin/dockerd"),
        ("identity-stack.service", "ExecStartPre", "/usr/local/libexec/platform/identity-verify-release"),
        ("identity-stack.service", "ExecStart", "/usr/local/lib/docker/cli-plugins/docker-compose"),
        ("identity-stack.service", "ExecStop", "/usr/local/lib/docker/cli-plugins/docker-compose"),
    )
    required = (
        '  trap - ERR',
        '  trap finish_unit_verification EXIT',
        '    local status=$?',
        '      report_configure_failure "$verification_stage" "$status" "$verification_stdout" "$verification_stderr"',
        '    rm -rf -- "$verification_root"',
        '    exit "$status"',
        '  verification_stage=UNIT_TRANSFORM',
        '  verification_stage=UNIT_SYSTEMD',
        '    >"$verification_root/transform.stdout" \\',
        '    2>"$verification_root/transform.stderr" <<\'PY\'',
        '"docker.service": gzip.decompress(base64.b64decode(sys.argv[5], validate=True))',
        '"identity-stack.service": gzip.decompress(base64.b64decode(sys.argv[6], validate=True))',
        "if staged_bytes != canonical_units[unit_name]:",
        'if all_original.count(token.encode("ascii")) != count:',
        "if len(matches) != 1 or transformed.count(prefix) != 1:",
        "if replacement_count != 4:",
        "if reversed_bytes.count(replacement) != 1:",
        "if reversed_bytes != originals[unit_name]:",
        "or path.is_symlink()",
        "exact_ancestor_chain(executable)",
        "exact_regular(executable, 0o755)",
        "if not os.access(executable, os.X_OK):",
        "systemd-analyze --recursive-errors=yes verify \\",
        '    "$copies_root/docker.service" \\',
        '    "$copies_root/identity-stack.service" \\',
        '    >"$verification_root/systemd.stdout" \\',
        '    2>"$verification_root/systemd.stderr"',
    )
    token_counts = '''expected_token_counts = {
    "/usr/local/bin/dockerd": 1,
    "/usr/local/libexec/platform/identity-verify-release": 1,
    "/usr/local/lib/docker/cli-plugins/docker-compose": 2,
}'''
    production_call = '''verify_staged_units \\
  "$work_root/active" \\
  "$unit_verification_root" \\
  0 \\
  0 \\
  '${docker_service_b64gzip}' \\
  '${systemd_unit_b64gzip}'
[[ ! -e "$unit_verification_root" && ! -L "$unit_verification_root" ]]'''
    forbidden = ("--root=", "|| true", ">/dev/null", "2>/dev/null", "grep ", "bind")
    valid = (
        mapping == expected
        and all(verifier.count(item) == 1 for item in required)
        and verifier.count(token_counts) == 1
        and all(item not in verifier for item in forbidden)
        and source.count("systemd-analyze --recursive-errors=yes verify") == 1
        and "systemd-analyze verify" not in source
        and source.count(production_call) == 1
        and source.count("--unit-verification-fixture") == 1
        and source.index(production_call) < source.index("transaction_started=true")
        and verifier.index('      report_configure_failure ') < verifier.index('    rm -rf -- "$verification_root"') < verifier.index('    exit "$status"')
        and source.count('report_configure_failure "$configure_stage" "$original_status" - -') == 1
        and 'f"{label}_sha256={hashlib.sha256(value).hexdigest()}"' in source
        and 'f"{label}_lines={len(value.splitlines())}"' in source
        and 'f"{label}_bytes={len(value)}"' in source
        and 'if stage not in allowed or not status.isdecimal() or not 1 <= int(status) <= 255:' in source
    )
except (OSError, UnicodeError, ValueError, SyntaxError):
    valid = False
raise SystemExit(0 if valid else 1)
PY
  then
    fail "Identity staged-unit verification must retain the exact copy-only mapping, byte proof, executable checks, real systemd invocation, propagation, and cleanup"
  fi
}

if [[ -n "${IDENTITY_PUBLISHER_POLICY_FIXTURE:-}" ]]; then
  fixture_file="$IDENTITY_PUBLISHER_POLICY_FIXTURE"
  if [[ "$fixture_file" != /tmp/* || ! -f "$fixture_file" || -L "$fixture_file" \
    || "$fixture_file" != "$(realpath -e -- "$fixture_file")" ]]; then
    fail "Identity publisher policy fixture must be one external regular disposable file"
  else
    check_identity_publisher "$fixture_file"
  fi
  ((failures == 0)) || exit 1
  printf 'Production Identity publisher policy fixture passed.\n'
  exit 0
fi

if [[ -n "${IDENTITY_OIDC_POLICY_FIXTURE:-}" ]]; then
  fixture_file="$IDENTITY_OIDC_POLICY_FIXTURE"
  if [[ "$fixture_file" != /tmp/* || ! -f "$fixture_file" || -L "$fixture_file" \
    || "$fixture_file" != "$(realpath -e -- "$fixture_file")" ]]; then
    fail "Identity OIDC policy fixture must be one external regular disposable file"
  else
    check_identity_oidc_trust "$fixture_file"
  fi
  ((failures == 0)) || exit 1
  printf 'Production Identity OIDC policy fixture passed.\n'
  exit 0
fi

check_identity_document_bounds() {
  local runtime_identity_file="$1"
  local documents_file="$2"
  local configure_file="$3"
  local verify_file="$4"

  require_count 12 'base64gzip[(]' "$runtime_identity_file" \
    "configure payloads must use exactly twelve OpenTofu base64gzip expressions"
  reject 'base64encode[(]' "$runtime_identity_file" \
    "configure payloads must not restore uncompressed base64 encoding"
  require_count 12 '^write_b64gzip '\''\$\{[a-z_]+_b64gzip\}'\''' "$configure_file" \
    "configure must decode exactly twelve compressed embedded payloads"
  require_fixed "$configure_file" 'write_b64gzip() {' \
    "configure must retain the fixed compressed-payload writer"
  require_fixed "$configure_file" 'expected_metadata="$${mode#0}:$(id -u):$(id -g)"' \
    "configure must retain exact staged-payload metadata validation"
  require_fixed "$configure_file" 'install -m "$mode" /dev/null "$temporary"' \
    "configure must create each private staged payload with its exact mode"
  require_fixed "$configure_file" 'if ! printf '\''%s'\'' "$encoded" | base64 --decode | gzip --decompress >"$temporary"; then' \
    "configure must fail closed on fixed base64 and gzip decoding"
  require_fixed "$configure_file" 'mv -Tf -- "$temporary" "$destination"' \
    "configure must atomically publish every decoded payload"
  reject '^[[:space:]]*write_b64[(]|base64 --decode[[:space:]]*>' "$configure_file" \
    "configure must not restore its raw-base64 writer"
  check_manual_active_staging_parents "$configure_file"
  check_staged_unit_verification "$configure_file"
  require_count 1 '^[[:space:]]*condition[[:space:]]*=[[:space:]]*length[(]base64encode[(]local[.]rendered_document_contents\[each[.]key\][)][)][[:space:]]*<=[[:space:]]*81920[[:space:]]*$' "$documents_file" \
    "every rendered SSM document must retain the exact 61,440-byte base64-length guard"
  require_count 1 '^[[:space:]]*error_message[[:space:]]*=[[:space:]]*"The rendered UTF-8 SSM document must not exceed 61,440 bytes[.]"[[:space:]]*$' "$documents_file" \
    "the rendered SSM document size guard must retain its exact diagnostic"

  if grep -Fq '{{' "$verify_file"; then
    fail "the stored verify document must contain zero literal undeclared SSM interpolation tokens"
  fi
  require_fixed "$verify_file" 'docker_template_open="$(printf '\''%s%s'\'' '\''{'\'' '\''{'\'')"' \
    "verify must construct the Docker template opener from safe fragments"
  require_fixed "$verify_file" 'docker_template_close="$(printf '\''%s%s'\'' '\''}'\'' '\''}'\'')"' \
    "verify must construct the Docker template closer from safe fragments"
  require_fixed "$verify_file" 'readonly docker_running_template="${docker_template_open}.State.Running${docker_template_close}"' \
    "verify must construct the exact Docker running template"
  require_fixed "$verify_file" 'readonly docker_health_template="${docker_template_open}if .State.Health${docker_template_close}${docker_template_open}.State.Health.Status${docker_template_close}${docker_template_open}end${docker_template_close}"' \
    "verify must construct the exact Docker conditional-health template"
  require_fixed "$verify_file" 'readonly docker_health_status_template="${docker_template_open}.State.Health.Status${docker_template_close}"' \
    "verify must construct the exact Docker health-status template"
  require_fixed "$verify_file" 'readonly docker_restart_template="${docker_template_open}.RestartCount${docker_template_close}"' \
    "verify must construct the exact Docker restart-count template"
  reject '(^|[[:space:]])eval([[:space:]]|$)' "$verify_file" \
    "verify must not evaluate constructed Docker templates as shell code"
}

if [[ -n "${IDENTITY_DOCUMENT_POLICY_FIXTURE:-}" ]]; then
  fixture_root="$IDENTITY_DOCUMENT_POLICY_FIXTURE"
  if [[ "$fixture_root" != /tmp/* || ! -d "$fixture_root" || -L "$fixture_root" \
    || "$fixture_root" != "$(realpath -e -- "$fixture_root")" ]]; then
    fail "Identity document policy fixture must be one external real disposable directory"
  else
    fixture_files=(
      infra/live/production/runtime/identity.tf
      infra/modules/identity_production/documents.tf
      deploy/ssm/configure-identity-runtime.sh.tftpl
      deploy/ssm/verify-identity.sh
    )
    for fixture_file in "${fixture_files[@]}"; do
      [[ -f "$fixture_root/$fixture_file" && ! -L "$fixture_root/$fixture_file" ]] \
        || fail "Identity document policy fixture is missing one required regular source"
    done
    if ((failures == 0)); then
      check_identity_document_bounds \
        "$fixture_root/infra/live/production/runtime/identity.tf" \
        "$fixture_root/infra/modules/identity_production/documents.tf" \
        "$fixture_root/deploy/ssm/configure-identity-runtime.sh.tftpl" \
        "$fixture_root/deploy/ssm/verify-identity.sh"
    fi
  fi
  ((failures == 0)) || exit 1
  printf 'Production Identity document policy fixture passed.\n'
  exit 0
fi

check_google_idp_normalization() {
  local file="$1"
  local google_block
  local provider_details_block
  local ignore_list

  google_block="$(extract_braced_block '^[[:space:]]*resource[[:space:]]+"aws_cognito_identity_provider"[[:space:]]+"google"[[:space:]]*\{' <"$file")"
  if [[ -z "$google_block" ]]; then
    fail "Google IdP normalization requires the sole exact resource block"
    return
  fi

  require_text_count 1 '^[[:space:]]*user_pool_id[[:space:]]*=[[:space:]]*var[.]user_pool_id[[:space:]]*$' \
    "$google_block" "Google IdP normalization must retain the managed pool binding"
  require_text_count 1 '^[[:space:]]*provider_name[[:space:]]*=[[:space:]]*"Google"[[:space:]]*$' \
    "$google_block" "Google IdP normalization must retain the managed provider name"
  require_text_count 1 '^[[:space:]]*provider_type[[:space:]]*=[[:space:]]*"Google"[[:space:]]*$' \
    "$google_block" "Google IdP normalization must retain the managed provider type"
  require_text_count 1 '^[[:space:]]*idp_identifiers[[:space:]]*=[[:space:]]*\[\][[:space:]]*$' \
    "$google_block" "Google IdP normalization must explicitly manage one empty identifier collection"
  require_text_count 1 '^[[:space:]]*idp_identifiers[[:space:]]*=' \
    "$google_block" "Google IdP normalization must contain exactly one identifier assignment"
  require_text_count 1 '^[[:space:]]*prevent_destroy[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
    "$google_block" "Google IdP normalization must retain prevent_destroy"

  provider_details_block="$(extract_braced_block '^[[:space:]]*provider_details[[:space:]]*=[[:space:]]*\{' <<<"$google_block")"
  require_text_count 1 '^[[:space:]]*provider_details[[:space:]]*=[[:space:]]*\{[[:space:]]*$' \
    "$google_block" "Google IdP must retain exactly one request-controlled provider-details map"
  require_text_count 3 '^[[:space:]]{4}[a-z_]+[[:space:]]*=' \
    "$provider_details_block" "Google IdP provider details must contain exactly three request-controlled keys"
  require_text_count 1 '^[[:space:]]*authorize_scopes[[:space:]]*=[[:space:]]*"openid email"[[:space:]]*$' \
    "$provider_details_block" "Google IdP must retain the managed authorize scopes"
  require_text_count 1 '^[[:space:]]*client_id[[:space:]]*=[[:space:]]*try[(]local[.]google_credentials[.]client_id,[[:space:]]*null[)][[:space:]]*$' \
    "$provider_details_block" "Google IdP must retain the managed client ID expression"
  require_text_count 1 '^[[:space:]]*client_secret[[:space:]]*=[[:space:]]*try[(]local[.]google_credentials[.]client_secret,[[:space:]]*null[)][[:space:]]*$' \
    "$provider_details_block" "Google IdP must retain the managed client-secret expression"

  require_text_count 1 '^[[:space:]]*ignore_changes[[:space:]]*=[[:space:]]*\[[[:space:]]*$' \
    "$google_block" "Google IdP normalization must contain exactly one narrow ignore list"
  require_text_count 1 '^[[:space:]]*ignore_changes[[:space:]]*=' \
    "$google_block" "Google IdP normalization must not add a second or broad ignore rule"
  ignore_list="$(extract_bracketed_list '^[[:space:]]*ignore_changes[[:space:]]*=[[:space:]]*\[' <<<"$google_block")"
  require_text_count 6 '^[[:space:]]*provider_details\["[a-z_]+"\],[[:space:]]*$' \
    "$ignore_list" "Google IdP normalization must ignore exactly six indexed response-only fields"
  require_text_count 6 ',[[:space:]]*$' \
    "$ignore_list" "Google IdP normalization must contain no broad or additional ignore entries"

  local response_field
  for response_field in attributes_url attributes_url_add_attributes authorize_url oidc_issuer token_request_method token_url; do
    require_text_count 1 "^[[:space:]]*provider_details\\[\"$response_field\"\\],[[:space:]]*$" \
      "$ignore_list" "Google IdP normalization is missing or duplicating a required response-only ignore"
  done
}

core_values=infra/live/production/core/production.tfvars
core_variables=infra/live/production/core/variables.tf
core_outputs=infra/live/production/core/outputs.tf
runtime_values=infra/live/production/runtime/runtime.tfvars
runtime_variables=infra/live/production/runtime/variables.tf
runtime_outputs=infra/live/production/runtime/outputs.tf
runtime_identity=infra/live/production/runtime/identity.tf
authentication=infra/modules/identity_authentication/main.tf
custody=infra/modules/identity_secret_custody/main.tf
production_module=infra/modules/identity_production
compose=config/runtime/identity-compose.yml.tftpl
images=config/runtime/identity-images.json
nginx=config/nginx/identity-runtime.conf.tftpl
pgbackrest=config/runtime/pgbackrest.conf.tftpl
production_document=docs/production-identity.md
configure=deploy/ssm/configure-identity-runtime.sh.tftpl
deploy=deploy/ssm/deploy-identity.sh
rollback=deploy/ssm/rollback-identity.sh
backup=deploy/ssm/backup-identity.sh
restore=deploy/ssm/restore-identity.sh
release_verifier=deploy/ssm/verify-identity-release.sh
verify=deploy/ssm/verify-identity.sh
roles=config/runtime/postgres-roles.sql
deployment_fixture=tests/deployment/check-identity.sh
runtime_fixture=tests/runtime/check-identity-fixtures.sh

for file in "$core_values" "$core_variables" "$core_outputs" "$runtime_values" "$runtime_variables" \
  "$runtime_outputs" "$runtime_identity" "$authentication" "$custody" "$production_module/ecr.tf" \
  "$production_module/github_oidc.tf" "$production_module/iam.tf" \
  "$production_module/documents.tf" "$production_module/monitoring.tf" "$compose" "$images" "$nginx" "$pgbackrest" "$production_document" \
  "$configure" "$deploy" "$rollback" "$backup" "$restore" "$release_verifier" "$verify" "$roles" "$deployment_fixture" "$runtime_fixture"; do
  [[ -f "$file" ]] || fail "a required production Identity source file is missing"
done
((failures == 0)) || exit 1

check_identity_document_bounds "$runtime_identity" "$production_module/documents.tf" "$configure" "$verify"
((failures == 0)) || exit 1

require_count 1 '^[[:space:]]*instance_type[[:space:]]*=[[:space:]]*"t4g[.]medium"[[:space:]]*$' "$core_values" \
  "the committed production host direction must be exactly t4g.medium"
require_count 1 '^[[:space:]]*root_volume_size_gib[[:space:]]*=[[:space:]]*30[[:space:]]*$' "$core_values" \
  "the production root volume must remain exactly 30 GiB"

for gate in enable_identity_cognito_core enable_identity_auth_certificate \
  enable_identity_auth_certificate_validation enable_identity_google_federation \
  enable_identity_auth_domain enable_identity_reference_bff_client \
  enable_identity_client_secret_custody; do
  require_count 1 "^[[:space:]]*$gate[[:space:]]*=[[:space:]]*false[[:space:]]*$" "$core_values" \
    "every committed authentication-plane gate must remain false"
done
for gate in enable_identity_delivery_foundation enable_identity_production_runtime; do
  require_count 1 "^[[:space:]]*$gate[[:space:]]*=[[:space:]]*false[[:space:]]*$" "$runtime_values" \
    "every committed delivery/runtime gate must remain false"
done
for input in identity_api_image identity_bff_image identity_api_image_platform identity_bff_image_platform \
  identity_auth_certificate_arn identity_cognito_issuer identity_cognito_jwks_uri \
  identity_cognito_audience identity_cognito_client_id identity_bff_origin identity_github_owner_id \
  identity_github_repository_id identity_bff_client_secret_arn \
  identity_database_secret_arn identity_redis_secret_arn identity_backup_secret_arn; do
  require_count 1 "^[[:space:]]*$input[[:space:]]*=[[:space:]]*null[[:space:]]*$" "$runtime_values" \
    "committed runtime activation references must remain null"
done
require_count 1 '^[[:space:]]*identity_google_credentials_secret_arn[[:space:]]*=[[:space:]]*null[[:space:]]*$' "$core_values" \
  "the committed Google credential reference must remain null"
require_count 1 '^[[:space:]]*identity_reference_bff_application_origins[[:space:]]*=[[:space:]]*\[\][[:space:]]*$' "$core_values" \
  "the committed application-origin collection must remain empty"

require_fixed "$core_variables" 'var.enable_identity_auth_certificate_validation &&' \
  "the custom domain must require validated ACM DNS"
require_count 1 '^[[:space:]]*var[.]identity_reference_bff_application_origins[[:space:]]*==[[:space:]]*tolist[(]\[format[(]"https://%s",[[:space:]]*var[.]base_domain[)]\][)][[:space:]]*$' "$core_variables" \
  "the confidential client must require the type-stable exact portfolio origin"
reject '^[[:space:]]*var[.]identity_reference_bff_application_origins[[:space:]]*==[[:space:]]*\[format[(]"https://%s",[[:space:]]*var[.]base_domain[)]\][[:space:]]*$' "$core_variables" \
  "the confidential client must reject the type-unstable tuple comparison"
require_fixed "$runtime_variables" 'var.enable_identity_delivery_foundation &&' \
  "the runtime must require the delivery foundation"
require_fixed "$runtime_variables" 'var.identity_api_image_platform == "linux/arm64"' \
  "the runtime must require an API ARM64 proof"
require_fixed "$runtime_variables" 'var.identity_bff_image_platform == "linux/arm64"' \
  "the runtime must require a BFF ARM64 proof"
require_fixed "$runtime_variables" 'var.identity_redis_namespace == "reference-bff:production:portfolio:identity"' \
  "the runtime must retain the exact disposable Redis namespace"

require_count 1 '^[[:space:]]*resource "aws_acm_certificate" "auth"' "$authentication" \
  "the authentication module must contain one ACM certificate"
require_count 1 '^[[:space:]]*resource "aws_acm_certificate_validation" "auth"' "$authentication" \
  "the authentication module must contain one ACM validation"
require_count 1 '^[[:space:]]*data "aws_secretsmanager_secret_version" "google"' "$authentication" \
  "Google credentials must use one staged secret reference"
require_count 1 '^[[:space:]]*resource "aws_cognito_identity_provider" "google"' "$authentication" \
  "the authentication module must contain one Google provider"
require_count 1 '^[[:space:]]*resource "aws_cognito_user_pool_domain" "auth"' "$authentication" \
  "the authentication module must contain one Cognito custom domain"
require_count 3 '^[[:space:]]*prevent_destroy[[:space:]]*=[[:space:]]*true' "$authentication" \
  "certificate, Google provider, and domain destruction guards must remain"
require_fixed "$authentication" 'provider = aws.us_east_1' \
  "the auth certificate must use the us-east-1 alias"
require_count 1 '^[[:space:]]*provider_name[[:space:]]*=[[:space:]]*"Google"[[:space:]]*$' "$authentication" \
  "the sole Cognito identity provider must be Google"
reject 'resource "aws_route53|"(COGNITO|Facebook|LoginWithAmazon|SignInWithApple|SAML)"' "$authentication" \
  "authentication source must not manage DNS or add another identity provider"

check_google_idp_normalization "$authentication"
if [[ -n "${GOOGLE_IDP_POLICY_FIXTURE:-}" ]]; then
  if [[ "$GOOGLE_IDP_POLICY_FIXTURE" != /tmp/* || ! -f "$GOOGLE_IDP_POLICY_FIXTURE" || -L "$GOOGLE_IDP_POLICY_FIXTURE" ]]; then
    fail "Google IdP policy fixture must be one external regular disposable file"
  else
    check_google_idp_normalization "$GOOGLE_IDP_POLICY_FIXTURE"
  fi
fi

require_count 1 '^[[:space:]]*resource "aws_secretsmanager_secret" "reference_bff_client"' "$custody" \
  "secret custody must contain one metadata resource"
require_count 1 '^[[:space:]]*resource "aws_secretsmanager_secret_version" "reference_bff_client"' "$custody" \
  "secret custody must contain one version resource"
require_count 2 '^[[:space:]]*prevent_destroy[[:space:]]*=[[:space:]]*true' "$custody" \
  "secret metadata and generated-secret version must retain destruction protection"
reject '(client_secret|secret_string|sensitive[[:space:]]*=[[:space:]]*true)' "$core_outputs" \
  "the production core must not expose secret material"
reject '(client_secret|secret_arn|secret_string|sensitive[[:space:]]*=[[:space:]]*true)' "$runtime_outputs" \
  "the production runtime must not expose secret material"

require_count 1 '^[[:space:]]*resource "aws_ecr_repository" "identity"' "$production_module/ecr.tf" \
  "delivery must use one exact two-member ECR resource block"
require_fixed "$production_module/ecr.tf" 'image_tag_mutability = "IMMUTABLE"' \
  "Identity repositories must reject mutable tags"
require_fixed "$production_module/ecr.tf" 'scan_on_push = true' \
  "Identity repositories must scan every push"
require_fixed "$production_module/ecr.tf" 'encryption_type = "AES256"' \
  "Identity repositories must remain encrypted"
require_fixed "$production_module/ecr.tf" 'prevent_destroy = true' \
  "Identity repositories must retain destruction guards"
check_identity_oidc_trust "$production_module/github_oidc.tf"
check_identity_publisher "$production_module/iam.tf"
reject '(AdministratorAccess|secretsmanager:[*])' "$production_module/iam.tf" \
  "Identity IAM must not contain administrative or wildcard secret permissions"
require_fixed "$production_module/variables.tf" '!strcontains(lower(arn), "google")' \
  "the host secret contract must reject Google credentials"
require_fixed "$production_module/variables.tf" 'length(var.runtime_secret_arns) == 4' \
  "the host must read exactly four purpose-bound runtime secrets"
require_fixed "$production_module/iam.tf" 'values   = ["identity/production/*"]' \
  "the host backup ListBucket permission must remain prefix-scoped"

jq -e '
  .postgres.version == "18.4" and .postgres.platform == "linux/arm64/v8" and
  (.postgres.image | test("@sha256:[0-9a-f]{64}$")) and
  .redis.version == "8.2.1" and .redis.platform == "linux/arm64/v8" and
  (.redis.image | test("@sha256:[0-9a-f]{64}$")) and
  .pgbackrest.version == "2.59.1" and .pgbackrest.platform == "linux/arm64" and
  (.pgbackrest.image | test("@sha256:[0-9a-f]{64}$")) and
  .docker.version == "29.7.2" and .docker.platform == "linux/arm64" and
  .compose.version == "2.40.3" and .compose.platform == "linux/arm64"
' "$images" >/dev/null || fail "support images and releases must remain exact digest-pinned ARM64 identities"
reject '(:latest|image:[[:space:]]+[^#[:space:]]+:[A-Za-z0-9])' "$compose" \
  "Compose source must not use mutable image tags"
require_fixed "$compose" 'ports: [127.0.0.1:8081:8080]' "the API must bind only to loopback"
require_fixed "$compose" 'ports: [127.0.0.1:8082:8081]' "the BFF must bind only to its published loopback port"
reject 'ports:.*(5432|6379)|/var/run/docker.sock|/run/docker.sock' "$compose" \
  "state ports and the Docker socket must not be published or mounted"
require_fixed config/runtime/identity-launcher.py 'sslmode=verify-full&sslrootcert=/run/tls/postgres/ca.crt' \
  "the launcher must construct the exact verify-full PostgreSQL URL"
require_fixed config/runtime/identity-launcher.py 'rediss://portfolio_bff:{encoded}@redis:6379/0' \
  "the launcher must construct the exact authenticated Redis TLS URL"
require_fixed config/runtime/identity-launcher.py 'REDIS_NAMESPACE = "reference-bff:production:portfolio:identity"' \
  "Redis must remain exactly namespaced"
reject '(BFF_COOKIE_ENCRYPTION_KEY_FILE|cookie_encryption|identity_bff_runtime_secret_arn)' "$compose" \
  "the unused BFF cookie-secret contract must remain absent"
reject '(BFF_COOKIE_DOMAIN|SESSION_COOKIE_DOMAIN|COOKIE_DOMAIN):' "$compose" \
  "the BFF must not configure a shared cookie domain"
require_fixed "$compose" '--appendonly' "Redis persistence must remain explicitly disabled"
require_fixed "$compose" '- "no"' "Redis append-only persistence must remain disabled"
require_fixed "$compose" '--save' "Redis snapshot persistence must remain explicitly disabled"
require_fixed "$compose" '- ""' "Redis snapshot persistence must remain disabled"
require_fixed "$compose" 'volatile-ttl' "Redis eviction must remain expiry-compatible"
require_fixed "$pgbackrest" 'repo1-cipher-type=aes-256-cbc' "pgBackRest repository encryption must remain enabled"
reject '^pg1-(host|port)=' "$pgbackrest" "pgBackRest must use only the shared administrative PostgreSQL socket"
require_count 1 '^[[:space:]]*network_mode:[[:space:]]*host[[:space:]]*$' "$compose" \
  "only the listener-free pgBackRest sidecar may retain host-role credential reachability"
require_count 6 '^[[:space:]]*driver:[[:space:]]*awslogs[[:space:]]*$' "$compose" \
  "every Identity workload and state service must use the host-role CloudWatch Logs driver"
require_fixed "$production_document" 'Redis loss' "Redis loss must remain documented as session-invalidating"
require_fixed "$production_document" 'no recovery claim is made' "Redis must retain an explicit no-recovery statement"
require_fixed "$production_document" 'PLATFORM-P4-REDIS-RECOVERY-DESIGN-001' "Redis recovery must remain an explicit future design task"
require_count 5 '^[[:space:]]*read_only:[[:space:]]*true' "$compose" \
  "hardened containers must retain read-only roots"
require_count 5 '^[[:space:]]*cap_drop:[[:space:]]*\[ALL\]' "$compose" \
  "every explicit container hardening boundary must drop capabilities"

require_count 1 '^[[:space:]]*location \^~ /auth/ \{' "$nginx" "the apex must have one BFF auth route"
require_count 1 '^[[:space:]]*location \^~ /api/ \{' "$nginx" "the apex must have one BFF API route"
require_count 2 '^[[:space:]]*server_name identity[.]\$\{base_domain\};' "$nginx" \
  "the dedicated Identity API HTTP and HTTPS virtual hosts must remain exact"
reject 'server_name[[:space:]]+auth[.]|proxy_pass[^;]*auth[.]' "$nginx" \
  "auth DNS must never terminate at or proxy through Nginx"
require_fixed "$nginx" 'return 308 https://${base_domain}$request_uri;' \
  "canonical redirects must preserve path and query"
require_fixed "$nginx" 'return 308 https://identity.${base_domain}$request_uri;' \
  "Identity HTTP redirects must preserve the Identity host"

for operation in configure deploy tls verify rollback backup restore; do
  require_fixed "$production_module/documents.tf" "$operation" \
    "every fixed Identity operation document must remain present"
done
require_fixed deploy/ssm/deploy-identity.sh 'run --rm migrator' "migration must precede activation"
require_fixed deploy/ssm/deploy-identity.sh '0001_initial_identity_schema' "deployment must require the exact migration head"
reject 'migrator check|command: \[migrate' deploy/ssm/deploy-identity.sh \
  "deployment must not invoke nonexistent migration commands"
require_fixed deploy/ssm/backup-identity.sh 'pgbackrest' "backup must use pgBackRest"
require_fixed deploy/ssm/restore-identity.sh 'identity-restore-rehearsal' \
  "restore must target an isolated rehearsal directory"
for lifecycle_file in "$configure" "$deploy" "$rollback"; do
  require_fixed "$lifecycle_file" 'platform-identity-lifecycle.lock' \
    "configure, deploy, and rollback must share one exclusive lifecycle lock"
done
require_fixed "$configure" '--transaction-fixture' \
  "host configuration must retain its executable failure-atomic fixture"
require_fixed "$configure" 'rejected active host-global drift' \
  "host-global upgrades must fail closed while Identity is active"
require_fixed "$configure" 'already matches the active generation; no services changed' \
  "identical host configuration must remain a no-op"
require_fixed "$configure" 'source_metadata="$(stat -c '\''%a:%u:%g'\'' "$source")"' \
  "host-global no-op proof must compare exact file metadata"
require_fixed "$configure" 'all_directories_equal' \
  "host-global no-op proof must compare exact directory metadata"
require_fixed "$configure" 'rejected parent-directory metadata drift' \
  "host-global configuration must fail closed on parent-directory drift"
require_fixed "$release_verifier" '[[ "${#candidate_inventory[@]}" == 2 ]]' \
  "release verification must require the exact two-member inventory"
require_fixed "$release_verifier" '[[ "${candidate_inventory[0]}" == compose.yml:f ]]' \
  "release verification must require the exact Compose member type"
require_fixed "$release_verifier" '[[ "${candidate_inventory[1]}" == release.env:f ]]' \
  "release verification must require the exact environment member type"
require_fixed "$release_verifier" '"755:$expected_uid:$expected_gid"' \
  "release verification must require exact parent and root metadata"
require_fixed "$release_verifier" '"600:$expected_file_uid:$expected_file_gid"' \
  "release verification must require exact private environment metadata"
require_fixed "$release_verifier" '"644:$expected_file_uid:$expected_file_gid"' \
  "release verification must require exact Compose metadata"
require_fixed "$deploy" 'restore_prior_release' \
  "deployment must automatically restore and re-verify prior health"
require_fixed "$rollback" 'restore_original' \
  "rollback must automatically restore and re-verify original health"
require_fixed "$deploy" 'previous_promotion' \
  "deployment may promote the old release only after new health succeeds"
require_fixed "$roles" 'NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS' \
  "the PostgreSQL owner role must retain exact negative attributes"
require_fixed "$roles" 'LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS' \
  "the PostgreSQL migrator role must retain exact attributes"
require_fixed "$roles" 'LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS' \
  "the PostgreSQL runtime role must retain exact attributes"
require_fixed "$roles" 'AND (rolcanlogin OR rolinherit OR rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)' \
  "the PostgreSQL owner audit must reject INHERIT and every reviewed elevated attribute"
require_fixed "$roles" 'NOT membership.admin_option' \
  "the sole PostgreSQL membership must reject admin delegation"
require_fixed "$roles" 'membership.inherit_option' \
  "the sole PostgreSQL membership must retain inheritance"
require_fixed "$roles" 'membership.set_option' \
  "the sole PostgreSQL membership must retain SET authorization"
require_fixed "$roles" 'WITH ADMIN FALSE, INHERIT TRUE, SET TRUE' \
  "the PostgreSQL role grant must state every exact membership option"
require_fixed "$roles" 'IDENTITY_POST_MIGRATION_AUDIT' \
  "deployment must retain the exact current-head privilege audit"
require_fixed "$backup" 'platform_recovery.markers' \
  "backup must record its recovery marker before pgBackRest runs"
require_fixed "$restore" '--metadata-fixture' \
  "restore marker selection must retain an executable metadata fixture"
require_fixed "$restore" 'record[0] <= target and record[1] <= target' \
  "time-target restore must reject a marker newer than its target"
require_fixed "$runtime_fixture" 'pre_backup_marker_persistence' \
  "the packed fixture must prove marker persistence before backup"
require_fixed "$runtime_fixture" 'docker exec --interactive --env PGPASSWORD="$bootstrap_password" "$postgres"' \
  "the packed fixture must actually execute its stdin-fed recovery SQL"
require_fixed "$deployment_fixture" 'previous_promotion' \
  "executable lifecycle proof must include the post-health promotion boundary"
require_fixed "$deployment_fixture" 'config-file-mode-drift' \
  "executable configuration proof must inject active-file metadata drift"
require_fixed "$deployment_fixture" 'config-directory-mode-drift' \
  "executable configuration proof must inject parent-directory metadata drift"
require_fixed "$deployment_fixture" 'release-extra-member' \
  "executable release proof must inject an extra retained member"
require_fixed "$deployment_fixture" 'release-file-group-drift' \
  "executable release proof must inject wrong file ownership metadata"
require_fixed "$runtime_fixture" 'postgres_owner_inherit_drift' \
  "the packed PostgreSQL fixture must inject owner inheritance drift"
require_fixed "$runtime_fixture" 'postgres_owner_membership_drift' \
  "the packed PostgreSQL fixture must inject an extra role granted to owner"
require_fixed "$runtime_fixture" 'postgres_membership_admin_option_drift' \
  "the packed PostgreSQL fixture must inject admin-option drift"
require_fixed "$runtime_fixture" 'b7bfb6e29824326a9a354bf3c7d0fe6988d0117a' \
  "reused packed-application proof must bind the accepted immutable object"
require_fixed "$runtime_fixture" 'git diff --quiet c9e25c0e028f35f7d27297e1e0bdd90f77c2c107' \
  "reused packed-application proof must fail closed if an application input changed"
require_fixed "$runtime_fixture" 'identity_service_owner:identity_service_migrator:t:t:t' \
  "fresh PostgreSQL proof must end at the sole exact membership row and options"
require_fixed deploy/ssm/enable-identity-tls.sh 'identity.rahuly.in' \
  "the fixed Identity TLS operation must target only the exact API hostname"
require_count 6 '^[[:space:]]*(MON|TUE|WED|THU|FRI|SAT)[[:space:]]*=[[:space:]]*"[$][{]var[.]name_prefix[}]-identity-backup-diff-(mon|tue|wed|thu|fri|sat)"[[:space:]]*$' "$production_module/documents.tf" \
  "Identity differential backups must have six fixed single-weekday association names"
for fixed_weekday in \
  'MON = "${var.name_prefix}-identity-backup-diff-mon"' \
  'TUE = "${var.name_prefix}-identity-backup-diff-tue"' \
  'WED = "${var.name_prefix}-identity-backup-diff-wed"' \
  'THU = "${var.name_prefix}-identity-backup-diff-thu"' \
  'FRI = "${var.name_prefix}-identity-backup-diff-fri"' \
  'SAT = "${var.name_prefix}-identity-backup-diff-sat"'; do
  require_fixed "$production_module/documents.tf" "$fixed_weekday" \
    "Identity differential weekday/name pairs must remain exact"
done
require_count 1 '^[[:space:]]*for_each[[:space:]]*=[[:space:]]*var[.]enable_runtime[[:space:]]*[?][[:space:]]*local[.]identity_backup_diff_association_names[[:space:]]*:[[:space:]]*[{][}][[:space:]]*$' "$production_module/documents.tf" \
  "Identity differential associations must use the fixed six-key map"
require_count 1 '^[[:space:]]*schedule_expression[[:space:]]*=[[:space:]]*"cron[(]0 2 [?] [*] [$][{]each[.]key[}] [*][)]"[[:space:]]*$' "$production_module/documents.tf" \
  "Identity differential backups must use one single-weekday cron per keyed instance"
require_count 1 '^[[:space:]]*schedule_expression[[:space:]]*=[[:space:]]*"cron[(]0/30 [*] [*] [*] [?] [*][)]"[[:space:]]*$' "$production_module/documents.tf" \
  "Identity verification must use the supported thirty-minute association cron"
require_count 3 '^[[:space:]]*apply_only_at_cron_interval[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$production_module/documents.tf" \
  "all scheduled Identity associations must remain apply-only"
reject 'MON-SAT|MON,TUE|rate[(]30 minutes[)]' "$production_module/documents.tf" \
  "Identity associations must reject weekday ranges/lists and rate-plus-apply-only schedules"
require_fixed deploy/ssm/verify-identity.sh 'Dimensions=[{Name=InstanceId' \
  "Identity verification metrics must match the alarm InstanceId dimension"
require_count 1 '^[[:space:]]*resource "aws_cloudwatch_metric_alarm" "identity"' "$production_module/monitoring.tf" \
  "Identity alarms must extend the existing monitoring module"
require_fixed "$production_module/monitoring.tf" 'for_each = var.enable_runtime ? local.identity_alarms : {}' \
  "Identity alarms must remain runtime-gated"
require_fixed "$production_module/monitoring.tf" 'alarm_actions       = [var.alarm_topic_arn]' \
  "Identity alarms must notify the existing alarm topic"
require_fixed "$production_module/monitoring.tf" 'treat_missing_data  = "breaching"' \
  "a stopped verifier must not appear healthy"
require_count 8 '^[[:space:]]*resource "aws_cloudwatch_metric_alarm"' infra/modules/monitoring/alarms.tf \
  "the existing eight portfolio alarms must remain intact"

if ((failures > 0)); then
  printf 'Production Identity policy checks failed with %d contract violation(s).\n' "$failures" >&2
  exit 1
fi
python3 tests/runtime/verify-identity-contract.py . >/dev/null || fail "the executable Identity runtime contract must pass"
((failures == 0)) || exit 1
printf 'Production Identity policy checks passed.\n'
