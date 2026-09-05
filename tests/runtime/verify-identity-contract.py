#!/usr/bin/env python3
"""Value-free verifier for the production Identity runtime source contract."""

from __future__ import annotations

import ast
import pathlib
import re
import sys


root = pathlib.Path(sys.argv[1] if len(sys.argv) == 2 else ".").resolve()


def read(relative: str) -> str:
    try:
        return (root / relative).read_text(encoding="utf-8")
    except OSError:
        fail()


def require(condition: bool) -> None:
    if not condition:
        fail()


def fail() -> "NoReturn":
    print("Production Identity executable contract check failed safely.", file=sys.stderr)
    raise SystemExit(1)


def hcl_block(source: str, marker: str) -> str:
    try:
        start = source.index(marker)
        opening = source.index("{", start)
    except ValueError:
        fail()
    depth = 0
    for index in range(opening, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start : index + 1]
    fail()


launcher = read("config/runtime/identity-launcher.py")
compose = read("config/runtime/identity-compose.yml.tftpl")
roles = read("config/runtime/postgres-roles.sql")
configure = read("deploy/ssm/configure-identity-runtime.sh.tftpl")
deploy = read("deploy/ssm/deploy-identity.sh")
release = read("deploy/ssm/verify-identity-release.sh")
verify = read("deploy/ssm/verify-identity.sh")
restore = read("deploy/ssm/restore-identity.sh")
rollback = read("deploy/ssm/rollback-identity.sh")
backup = read("deploy/ssm/backup-identity.sh")
documents = read("infra/modules/identity_production/documents.tf")
iam = read("infra/modules/identity_production/iam.tf")
monitoring = read("infra/modules/identity_production/monitoring.tf")
module_variables = read("infra/modules/identity_production/variables.tf")
runtime_variables = read("infra/live/production/runtime/variables.tf")
runtime_identity = read("infra/live/production/runtime/identity.tf")
nginx = read("config/nginx/identity-runtime.conf.tftpl")
runtime_fixture = read("tests/runtime/check-identity-fixtures.sh")
oidc = read("infra/modules/identity_production/github_oidc.tf")

# Independently consume the entire operative trust grammar. Comments cannot
# supply an omitted guard, and extra attributes/blocks/principals cannot hide.
oidc_tokens = re.findall(
    r'"(?:\\.|[^"\\])*"|/\*.*?\*/|//[^\n]*|\#[^\n]*|[A-Za-z_][A-Za-z_0-9.-]*|[^\s]',
    oidc,
    re.DOTALL,
)
oidc_tokens = [token for token in oidc_tokens if not token.startswith(("#", "//", "/*"))]
oidc_cursor = 0


def consume_oidc(*expected: str) -> None:
    global oidc_cursor
    require(oidc_tokens[oidc_cursor:oidc_cursor + len(expected)] == list(expected))
    oidc_cursor += len(expected)


consume_oidc(
    "locals", "{", "github_subject", "=",
    '"repo:${var.github_owner}@${var.github_owner_id}/${var.github_repository}@${var.github_repository_id}:environment:${var.github_environment}"',
    "}", "data", '"aws_iam_policy_document"', '"github_assume"', "{", "statement", "{",
    "effect", "=", '"Allow"', "actions", "=", "[", '"sts:AssumeRoleWithWebIdentity"', "]",
    "principals", "{", "type", "=", '"Federated"', "identifiers", "=", "[",
    "var.github_oidc_provider_arn", "]", "}",
)
for claim, value in (
    ("aud", ('"sts.amazonaws.com"',)),
    ("sub", ("local.github_subject",)),
    ("repository_owner_id", ("tostring", "(", "var.github_owner_id", ")")),
    ("repository_id", ("tostring", "(", "var.github_repository_id", ")")),
):
    consume_oidc("condition", "{", "test", "=", '"StringEquals"', "variable", "=",
                 f'"token.actions.githubusercontent.com:{claim}"', "values", "=", "[",
                 *value, "]", "}")
consume_oidc(
    "}", "}", "resource", '"aws_iam_role"', '"github_identity_deployer"', "{",
    "name", "=", '"${var.name_prefix}-identity-deployer"', "assume_role_policy", "=",
    "data.aws_iam_policy_document.github_assume.json", "tags", "=", "var.tags", "}",
)
require(oidc_cursor == len(oidc_tokens))

# Independently consume the publisher's four statements and exact role binding.
# Host pull actions are outside this grammar and cannot supply publisher grants.
publisher_tokens = re.findall(
    r'"(?:\\.|[^"\\])*"|/\*.*?\*/|//[^\n]*|\#[^\n]*|[A-Za-z_][A-Za-z_0-9.-]*|[^\s]',
    iam,
    re.DOTALL,
)
publisher_tokens = [token for token in publisher_tokens if not token.startswith(("#", "//", "/*"))]
publisher_cursor = 0


def consume_publisher(*expected: str) -> None:
    global publisher_cursor
    require(publisher_tokens[publisher_cursor:publisher_cursor + len(expected)] == list(expected))
    publisher_cursor += len(expected)


consume_publisher(
    "data", '"aws_iam_policy_document"', '"github_identity_deployer"', "{",
    "statement", "{", "sid", "=", '"EcrLogin"', "effect", "=", '"Allow"',
    "actions", "=", "[", '"ecr:GetAuthorizationToken"', "]", "resources", "=", "[", '"*"', "]", "}",
    "statement", "{", "sid", "=", '"PublishIdentityImages"', "effect", "=", '"Allow"',
    "actions", "=", "[",
)
for action in (
    "BatchCheckLayerAvailability", "BatchGetImage", "CompleteLayerUpload",
    "InitiateLayerUpload", "PutImage", "UploadLayerPart",
):
    consume_publisher(f'"ecr:{action}"', ",")
consume_publisher(
    "]", "resources", "=", "[", "for", "repository", "in", "aws_ecr_repository.identity", ":", "repository.arn", "]", "}",
    "statement", "{", "sid", "=", '"RunReviewedIdentityDocuments"', "effect", "=", '"Allow"',
    "actions", "=", "[", '"ssm:SendCommand"', ",", "]", "resources", "=", "concat", "(",
    "[", '"arn:aws:ec2:${var.aws_region}:${var.expected_account_id}:instance/${var.instance_id}"', "]", ",",
    "[", "for", "key", "in", "[", '"deploy"', ",", '"verify"', ",", '"rollback"', "]", ":",
    "aws_ssm_document.identity", "[", "key", "]", ".", "arn", "]", ",", ")", "}",
    "statement", "{", "sid", "=", '"ObserveIdentityCommands"', "effect", "=", '"Allow"',
    "actions", "=", "[", '"ssm:GetCommandInvocation"', ",", '"ssm:ListCommandInvocations"', ",", "]",
    "resources", "=", "[", '"*"', "]", "}", "}",
    "resource", '"aws_iam_role_policy"', '"github_identity_deployer"', "{",
    "name", "=", '"${var.name_prefix}-identity-deployer"', "role", "=", "aws_iam_role.github_identity_deployer.id",
    "policy", "=", "data.aws_iam_policy_document.github_identity_deployer.json", "}",
)
for kind, resource_type in (("data", "aws_iam_policy_document"), ("resource", "aws_iam_role_policy")):
    consume_publisher(kind, f'"{resource_type}"', '"host_identity_runtime"', "{")
    depth = 1
    while depth and publisher_cursor < len(publisher_tokens):
        depth += (publisher_tokens[publisher_cursor] == "{") - (publisher_tokens[publisher_cursor] == "}")
        publisher_cursor += 1
    require(depth == 0)
require(publisher_cursor == len(publisher_tokens))

for fixed in (
    'API_UID = 10001',
    'BFF_UID = 10002',
    'AUTH_DOMAIN = "auth.rahuly.in"',
    'REDIS_NAMESPACE = "reference-bff:production:portfolio:identity"',
    '"APP_ENV": "production"',
    '"IDENTITY_ORIGIN": IDENTITY_ORIGIN',
    '"ALLOWED_HOSTS": \'["identity.rahuly.in"]\'',
    '"TRUSTED_PROXY_CIDRS": "[]"',
    '"ENABLE_INTERACTIVE_DOCS": "false"',
    '"COGNITO_USERINFO_URL": f"https://{AUTH_DOMAIN}/oauth2/userInfo"',
    '"OAUTH_RESOURCE": RESOURCE',
    '"BFF_ORIGIN": BFF_ORIGIN',
    '"ALLOWED_HOSTS": \'["rahuly.in"]\'',
    '"TRUSTED_PROXY_NETWORKS": "[]"',
    '"AUTHORIZATION_ENDPOINT": f"https://{AUTH_DOMAIN}/oauth2/authorize"',
    '"TOKEN_ENDPOINT": f"https://{AUTH_DOMAIN}/oauth2/token"',
    '"REDIS_KEY_NAMESPACE": REDIS_NAMESPACE',
    'os.execve(sys.executable, command, environment)',
    '[sys.executable, "-m", "identity_service.server"]',
    '[sys.executable, "scripts/migrate_local.py"]',
    '[sys.executable, "-m", "reference_bff.server"]',
):
    require(fixed in launcher)
for forbidden in ("subprocess", "shell=True", "identity_migrator", "portfolio:identity:bff:", "COGNITO_JWKS_URI", "REDIS_KEY_PREFIX"):
    require(forbidden not in launcher)
require(launcher.count("read_secret(") == 5)
require("lstat()" in launcher and "stat.S_ISREG" in launcher and "path.is_symlink()" in launcher)
require("urllib.parse.quote" in launcher and 'safe=""' in launcher)

for fixed in (
    'user: "10001:10001"',
    'user: "10002:10002"',
    'ports: [127.0.0.1:8081:8080]',
    'ports: [127.0.0.1:8082:8081]',
    'test: [CMD, python, scripts/healthcheck.py]',
    '--tls-auth-clients',
    '- "no"',
    'entrypoint: [python, /opt/platform/identity-launcher.py]',
):
    require(fixed in compose)
require(compose.count('entrypoint: [python, /opt/platform/identity-launcher.py]') == 3)
require(compose.count('test: [CMD, python, scripts/healthcheck.py]') == 2)
require('--tls-auth-clients\n      - "no"' in compose)
for purpose_path in ("secrets/redis-server", "secrets/redis-client", "tls/redis-server", "tls/redis-client", "tls/postgres-server", "tls/postgres-client"):
    require(purpose_path in compose)
for forbidden in ("65532:65532", "DATABASE_HOST:", "COGNITO_JWKS_URI:", "COGNITO_AUDIENCE:", "REDIS_USERNAME:", "REDIS_KEY_PREFIX:", "cookie_encryption", "client.crt", "client.key"):
    require(forbidden not in compose)

for fixed in (
    "identity_service_owner NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS",
    "identity_service_migrator LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS",
    "identity_service_app LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS",
    "CREATE SCHEMA IF NOT EXISTS identity AUTHORIZATION identity_service_owner",
    "GRANT USAGE ON SCHEMA identity TO identity_service_app",
    "GRANT identity_service_owner TO identity_service_migrator WITH ADMIN FALSE, INHERIT TRUE, SET TRUE",
    "NOT membership.admin_option",
    "membership.inherit_option",
    "membership.set_option",
    "identity runtime table privilege contract mismatch",
    "identity runtime column privilege contract mismatch",
    "identity_service_app'::regrole",
    "IDENTITY_POST_MIGRATION_AUDIT",
):
    require(fixed in roles)
for forbidden in ("identity_migrator", "identity_runtime", "GRANT SELECT, INSERT, UPDATE ON TABLES", "ALTER DEFAULT PRIVILEGES"):
    require(forbidden not in roles)

for fixed in (
    "object_pairs_hook=no_duplicates",
    '"client": {"client_secret"}',
    '"backup": {"repository_cipher"}',
    '"redis": {"bff_password", "redis_ca_crt", "redis_server_crt", "redis_server_key"}',
    "openssl verify -CAfile",
    "-checkhost \"$hostname\"",
    "SSL server : Yes",
    "platform-identity-lifecycle.lock",
    "identity-generations/$generation_name",
    "systemctl enable docker.service identity-stack.service",
    "! systemctl is-active --quiet identity-stack.service",
    "Active Identity workload requires a separately reviewed host maintenance operation.",
    "Identity runtime configuration already matches the active generation; no services changed.",
    "managed_directory_specs",
    "source_metadata=\"$(stat -c '%a:%u:%g' \"$source\")\"",
    "all_directories_equal",
    "rejected parent-directory metadata drift",
    "restore_transaction",
):
    require(fixed in configure)
require("bff_runtime_secret_arn" not in configure and "cookie_encryption" not in configure)
require(configure.count("fetch_secret \"") == 4)
for lifecycle_script in (configure, deploy, rollback):
    require("platform-identity-lifecycle.lock" in lifecycle_script)
require("rm -rf -- \"$obsolete_generation\"" not in configure)
systemd_verifier_index = configure.find("systemd-analyze --recursive-errors=yes verify")
require(
    systemd_verifier_index >= 0
    and systemd_verifier_index < configure.index("transaction_started=true")
)
require(configure.index("validate_server_identity") < configure.index("transaction_started=true"))
manual_parent_manifest = re.search(
    r"^readonly -a manual_active_staging_parent_specs=\(\n(?P<body>(?:  \"[^\n]+\"\n)+)\)$",
    configure,
    re.MULTILINE,
)
require(manual_parent_manifest is not None)
declared_manual_parents = re.findall(
    r'^  "([a-z0-9][a-z0-9/-]*):(0[0-7]{3})"$',
    manual_parent_manifest.group("body"),
    re.MULTILINE,
)
expected_manual_parents = [
    ("etc/systemd/system", "0755"),
    ("usr/local/libexec/platform", "0755"),
]
require(declared_manual_parents == expected_manual_parents)
manual_active_writes = re.findall(
    r'^write_b64gzip \'\$\{([a-z_]+)_b64gzip\}\' "\$work_root/active/([^\"]+)" (0[0-7]{3})$',
    configure,
    re.MULTILINE,
)
expected_manual_writes = [
    ("systemd_unit", "etc/systemd/system/identity-stack.service", "0644"),
    ("verify_release", "usr/local/libexec/platform/identity-verify-release", "0755"),
    ("health_verify", "usr/local/libexec/platform/identity-health-verify", "0755"),
    ("pgbackrest_sidecar", "usr/local/libexec/platform/pgbackrest-sidecar", "0755"),
    ("docker_service", "etc/systemd/system/docker.service", "0644"),
]
require(manual_active_writes == expected_manual_writes)
derived_manual_parents = sorted(
    {str(pathlib.PurePosixPath(destination).parent) for _, destination, _ in manual_active_writes}
)
require(derived_manual_parents == sorted(parent for parent, _ in declared_manual_parents))
parent_function_start = configure.index("prepare_manual_active_staging_parents() {")
parent_function_end = configure.index("\n}\n", parent_function_start) + 2
parent_function = configure[parent_function_start:parent_function_end]
for fixed in (
    'for specification in "$${manual_active_staging_parent_specs[@]}"; do',
    '[[ "$relative_parent" =~ ^[a-z0-9][a-z0-9/-]*$ && "$relative_parent" != *//* && "$relative_parent" != */../* && "$relative_parent" != ../* && "$relative_parent" != */.. ]]',
    '[[ "$mode" == 0755 ]]',
    'expected_metadata="$${mode#0}:$expected_uid:$expected_gid"',
    'if [[ -e "$parent" || -L "$parent" ]]; then',
    'install -d -m "$mode" -o "$expected_uid" -g "$expected_gid" "$parent"',
):
    require(parent_function.count(fixed) == 1)
parent_exact_check = '[[ -d "$parent" && ! -L "$parent" && "$(stat -c \'%a:%u:%g\' "$parent")" == "$expected_metadata" ]]'
require(parent_function.count(parent_exact_check) == 2)
require("continue" not in parent_function and "|| true" not in parent_function)
fixture_parent_call = 'prepare_manual_active_staging_parents "$fixture_active" "$fixture_uid" "$fixture_gid"'
production_parent_call = 'prepare_manual_active_staging_parents "$work_root/active" 0 0'
require(configure.count(fixture_parent_call) == 1)
require(configure.count(production_parent_call) == 1)
require(not re.search(r'install -d[^\n]*"\$work_root/active/(?:etc/systemd/system|usr/local/libexec/platform)"', configure))
production_parent_index = configure.index(production_parent_call)
manual_write_indexes = [
    configure.index(
        f"write_b64gzip '${{{payload}_b64gzip}}' \"$work_root/active/{destination}\" {mode}"
    )
    for payload, destination, mode in expected_manual_writes
]
require(
    manual_parent_manifest.start()
    < parent_function_start
    < production_parent_index
    < min(manual_write_indexes)
)
require(manual_write_indexes == sorted(manual_write_indexes))
require(
    max(manual_write_indexes)
    < configure.index('verify_staged_units \\\n  "$work_root/active"')
    < configure.index("transaction_started=true")
)
require("--active-staging-parent-fixture" in configure)

unit_verifier_start = configure.index("verify_staged_units() (")
unit_verifier_end = configure.index(
    '\n)\n\nif [[ "$*" == --unit-verification-fixture ]]', unit_verifier_start
) + 2
unit_verifier = configure[unit_verifier_start:unit_verifier_end]
mapping_match = re.search(
    r"^mapping = (?P<value>\(\n(?:    \([^\n]+\),\n)+\))$",
    unit_verifier,
    re.MULTILINE,
)
require(mapping_match is not None)
try:
    unit_mapping = ast.literal_eval(mapping_match.group("value"))
except (SyntaxError, ValueError):
    fail()
expected_unit_mapping = (
    ("docker.service", "ExecStart", "/usr/local/bin/dockerd"),
    (
        "identity-stack.service",
        "ExecStartPre",
        "/usr/local/libexec/platform/identity-verify-release",
    ),
    (
        "identity-stack.service",
        "ExecStart",
        "/usr/local/lib/docker/cli-plugins/docker-compose",
    ),
    (
        "identity-stack.service",
        "ExecStop",
        "/usr/local/lib/docker/cli-plugins/docker-compose",
    ),
)
require(unit_mapping == expected_unit_mapping)
for fixed in (
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
):
    require(unit_verifier.count(fixed) == 1)
for forbidden in (
    "--root=",
    "|| true",
    ">/dev/null",
    "2>/dev/null",
    "grep ",
    "bind",
):
    require(forbidden not in unit_verifier)
expected_token_count_block = '''expected_token_counts = {
    "/usr/local/bin/dockerd": 1,
    "/usr/local/libexec/platform/identity-verify-release": 1,
    "/usr/local/lib/docker/cli-plugins/docker-compose": 2,
}'''
require(unit_verifier.count(expected_token_count_block) == 1)
require(configure.count("systemd-analyze --recursive-errors=yes verify") == 1)
require("systemd-analyze verify" not in configure)
production_verifier_call = '''verify_staged_units \\
  "$work_root/active" \\
  "$unit_verification_root" \\
  0 \\
  0 \\
  '${docker_service_b64gzip}' \\
  '${systemd_unit_b64gzip}'
[[ ! -e "$unit_verification_root" && ! -L "$unit_verification_root" ]]'''
require(configure.count(production_verifier_call) == 1)
require(
    max(manual_write_indexes)
    < configure.index(production_verifier_call)
    < configure.index("transaction_started=true")
)
require(configure.count("--unit-verification-fixture") == 1)
require(configure.count('''[[ -d "$directory" && ! -L "$directory" && "$(stat -c '%a:%u:%g' "$directory")" == "$${mode#0}:0:0" ]]''') == 1)
require(
    unit_verifier.index('      report_configure_failure ')
    < unit_verifier.index('    rm -rf -- "$verification_root"')
    < unit_verifier.index('    exit "$status"')
)
for fixed in (
    'report_configure_failure "$configure_stage" "$original_status" - -',
    'f"{label}_sha256={hashlib.sha256(value).hexdigest()}"',
    'f"{label}_lines={len(value.splitlines())}"',
    'f"{label}_bytes={len(value)}"',
    'if stage not in allowed or not status.isdecimal() or not 1 <= int(status) <= 255:',
):
    require(configure.count(fixed) == 1)
for purpose_path in ("secrets/redis-server", "secrets/redis-client", "tls/redis-server", "tls/redis-client", "tls/postgres-server", "tls/postgres-client"):
    require(purpose_path in configure)

require(runtime_identity.count("base64gzip(") == 12)
require("base64encode(" not in runtime_identity)
for payload in (
    "compose",
    "nginx",
    "pgbackrest",
    "systemd_unit",
    "postgres_roles",
    "postgres_hba",
    "launcher",
    "verify_release",
    "health_verify",
    "pgbackrest_sidecar",
    "docker_service",
    "pgbackrest_passwd",
):
    require(f"{payload}_b64gzip" in runtime_identity)
    require(f"write_b64gzip '${{{payload}_b64gzip}}'" in configure)
require(configure.count("write_b64gzip '") == 12)
for fixed in (
    "write_b64gzip() {",
    'expected_metadata="$${mode#0}:$(id -u):$(id -g)"',
    'install -m "$mode" /dev/null "$temporary"',
    "if ! printf '%s' \"$encoded\" | base64 --decode | gzip --decompress >\"$temporary\"; then",
    'rm -f -- "$temporary"',
    '[[ -f "$temporary" && ! -L "$temporary" && "$(stat -c \'%a:%u:%g\' "$temporary")" == "$expected_metadata" ]]',
    'mv -Tf -- "$temporary" "$destination"',
    "--compressed-payload-fixture",
):
    require(fixed in configure)
require("write_b64()" not in configure)
require("base64 --decode >" not in configure)
require('condition     = length(base64encode(local.rendered_document_contents[each.key])) <= 81920' in documents)
require('error_message = "The rendered UTF-8 SSM document must not exceed 61,440 bytes."' in documents)
require(documents.count("rendered_document_contents") == 3)

for fixed in (
    "__IDENTITY_API_REPOSITORY_URL__",
    "__IDENTITY_BFF_REPOSITORY_URL__",
    "__IDENTITY_ECR_REGISTRY__",
    "aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin",
    "scripts/migrate_local.py",
    "0001_initial_identity_schema",
    "arm64/linux",
    "REDIS_KEY_NAMESPACE=reference-bff:production:portfolio:identity",
):
    require(fixed in deploy or fixed in launcher)
for forbidden in ("migrator check", "COGNITO_AUDIENCE=", "BFF_ORIGIN=%s", "docker login -p"):
    require(forbidden not in deploy)
require(deploy.count("run --rm migrator") == 1)
require(deploy.index("run --rm migrator") < deploy.index("SELECT version_num FROM identity.alembic_version"))
for fixed in (
    "activate_release",
    "restore_prior_release",
    '"$verify_release" "$release"',
    "previous_promotion",
    "platform_recovery.markers",
    "IDENTITY_POST_MIGRATION_AUDIT=1",
):
    require(fixed in deploy)
require(deploy.index('"$health_verify"') < deploy.rindex('atomic_link "$old_target" "$previous"'))

require("declare -A release=()" in release and '[[ "${#release[@]}" == 13 ]]' in release)
require('[[ "${#candidate_inventory[@]}" == 2 ]]' in release)
require('[[ "${candidate_inventory[0]}" == compose.yml:f ]]' in release)
require('[[ "${candidate_inventory[1]}" == release.env:f ]]' in release)
require('"600:$expected_file_uid:$expected_file_gid"' in release and '"644:$expected_file_uid:$expected_file_gid"' in release)
require('"755:$expected_uid:$expected_gid"' in release and "arm64/linux" in release)
require("REDIS_KEY_NAMESPACE" in release and "IDENTITY_SCHEMA_HEAD" in release)
require("source \"$release_file\"" not in release)

for fixed in (
    "b7bfb6e29824326a9a354bf3c7d0fe6988d0117a",
    "git diff --quiet c9e25c0e028f35f7d27297e1e0bdd90f77c2c107",
    "config/runtime/identity-launcher.py",
    "config/runtime/identity-compose.yml.tftpl",
    "postgres_owner_inherit_drift",
    "postgres_owner_membership_drift",
    "postgres_membership_admin_option_drift",
    "identity_service_owner:identity_service_migrator:t:t:t",
):
    require(fixed in runtime_fixture)

for command in ("GET", "SET", "GETDEL", "DEL", "EVAL"):
    require(command in verify)
require("reference-bff:production:portfolio:identity:verifier" in verify)
require("SELECT version_num FROM identity.alembic_version" in verify)
require("{{" not in verify)
for fixed in (
    "docker_template_open=\"$(printf '%s%s' '{' '{')\"",
    "docker_template_close=\"$(printf '%s%s' '}' '}')\"",
    'readonly docker_running_template="${docker_template_open}.State.Running${docker_template_close}"',
    'readonly docker_health_template="${docker_template_open}if .State.Health${docker_template_close}${docker_template_open}.State.Health.Status${docker_template_close}${docker_template_open}end${docker_template_close}"',
    'readonly docker_health_status_template="${docker_template_open}.State.Health.Status${docker_template_close}"',
    'readonly docker_restart_template="${docker_template_open}.RestartCount${docker_template_close}"',
    'docker inspect --format "$docker_running_template"',
    'docker inspect --format "$docker_health_template"',
    'docker inspect --format "$docker_health_status_template"',
    'docker inspect --format "$docker_restart_template"',
):
    require(fixed in verify)
require("eval " not in verify)
docker_template_open = "{" + "{"
docker_template_close = "}" + "}"
require(f"{docker_template_open}.State.Running{docker_template_close}" == "{{.State.Running}}")
require(
    f"{docker_template_open}if .State.Health{docker_template_close}"
    f"{docker_template_open}.State.Health.Status{docker_template_close}"
    f"{docker_template_open}end{docker_template_close}"
    == "{{if .State.Health}}{{.State.Health.Status}}{{end}}"
)
require(f"{docker_template_open}.State.Health.Status{docker_template_close}" == "{{.State.Health.Status}}")
require(f"{docker_template_open}.RestartCount{docker_template_close}" == "{{.RestartCount}}")

require("mktemp -d /var/lib/platform/identity-restore-rehearsal.XXXXXXXX" in restore)
require("docker rm -f \"$container\"" in restore and 'rm -rf -- "$restore_root"' in restore)
for fixed in ("platform_recovery.markers", "marker_created_at", "backup_label", "--set=\"$backup_label\"", "IDENTITY_SCHEMA_HEAD"):
    require(fixed in restore or fixed in release)
for fixed in ("restore_original", '"$verify_release" "$rollback_target"', "previous_promotion", "live_schema="):
    require(fixed in rollback)
require(rollback.index('"$health_verify"') < rollback.rindex('atomic_link "$original_target" "$previous"'))
require("0001_initial_identity_schema" in rollback)
for fixed in ("INSERT INTO platform_recovery.markers", "marker_created_at", "backup_label", "identity-backup-", "REVOKE ALL ON TABLE"):
    require(fixed in backup)

require('allowedPattern    = "^${replace(local.identity_api_repository_url' in documents)
require('allowedPattern    = "^${replace(local.identity_bff_repository_url' in documents)
expected_diff_names = {
    "MON": "mon",
    "TUE": "tue",
    "WED": "wed",
    "THU": "thu",
    "FRI": "fri",
    "SAT": "sat",
}
for weekday, suffix in expected_diff_names.items():
    require(
        documents.count(
            f'{weekday} = "${{var.name_prefix}}-identity-backup-diff-{suffix}"'
        )
        == 1
    )
require(documents.count('resource "aws_ssm_association"') == 4)
diff_association = hcl_block(
    documents, 'resource "aws_ssm_association" "identity_backup_diff"'
)
require(
    "for_each = var.enable_runtime ? local.identity_backup_diff_association_names : {}"
    in diff_association
)
require("association_name            = each.value" in diff_association)
require('schedule_expression         = "cron(0 2 ? * ${each.key} *)"' in diff_association)
require(diff_association.count("apply_only_at_cron_interval = true") == 1)
require('backupType = "diff"' in diff_association)
verify_association = hcl_block(
    documents, 'resource "aws_ssm_association" "verify_identity"'
)
require('schedule_expression         = "cron(0/30 * * * ? *)"' in verify_association)
require(verify_association.count("apply_only_at_cron_interval = true") == 1)
require("rate(30 minutes)" not in documents)
require("MON-SAT" not in documents and "MON,TUE" not in documents)
require(
    re.findall(
        r'^\s*schedule_expression\s*=\s*"([^"]+)"\s*$', documents, re.MULTILINE
    )
    == [
        "cron(0 2 ? * ${each.key} *)",
        "cron(0 2 ? * SUN *)",
        "cron(0/30 * * * ? *)",
    ]
)
require('["deploy", "verify", "rollback"]' in iam)
for excluded in ('aws_ssm_document.identity["configure"].arn', 'aws_ssm_document.identity["tls"].arn', 'aws_ssm_document.identity["backup"].arn', 'aws_ssm_document.identity["restore"].arn'):
    require(excluded not in iam)
require("length(var.runtime_secret_arns) == 4" in module_variables)
require("identity_bff_runtime_secret_arn" not in runtime_variables)
require('var.identity_redis_namespace == "reference-bff:production:portfolio:identity"' in runtime_variables)

require("for_each = var.enable_runtime ? local.identity_alarms : {}" in monitoring)
require("alarm_actions       = [var.alarm_topic_arn]" in monitoring)
require("treat_missing_data  = \"breaching\"" in monitoring)
require("period              = 1800" in monitoring)
require(len(re.findall(r'^ {4}[a-z_]+\s+= "Identity[A-Za-z]+"$', monitoring, re.MULTILINE)) == 13)

require(nginx.count("server_name identity.${base_domain};") == 2)
require("return 308 https://identity.${base_domain}$request_uri;" in nginx)
require("server_name auth.${base_domain}" not in nginx)

print("Production Identity executable contract checks passed.")
