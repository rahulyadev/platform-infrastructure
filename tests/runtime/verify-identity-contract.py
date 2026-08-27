#!/usr/bin/env python3
"""Value-free verifier for the production Identity runtime source contract."""

from __future__ import annotations

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
nginx = read("config/nginx/identity-runtime.conf.tftpl")

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
    "GRANT identity_service_owner TO identity_service_migrator WITH INHERIT TRUE, SET TRUE",
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
    "restore_transaction",
):
    require(fixed in configure)
require("bff_runtime_secret_arn" not in configure and "cookie_encryption" not in configure)
require(configure.count("fetch_secret \"") == 4)
for lifecycle_script in (configure, deploy, rollback):
    require("platform-identity-lifecycle.lock" in lifecycle_script)
require("rm -rf -- \"$obsolete_generation\"" not in configure)
require(configure.index("systemd-analyze verify") < configure.index("transaction_started=true"))
require(configure.index("validate_server_identity") < configure.index("transaction_started=true"))
for purpose_path in ("secrets/redis-server", "secrets/redis-client", "tls/redis-server", "tls/redis-client", "tls/postgres-server", "tls/postgres-client"):
    require(purpose_path in configure)

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
require("600:0:0" in release and "arm64/linux" in release)
require("REDIS_KEY_NAMESPACE" in release and "IDENTITY_SCHEMA_HEAD" in release)
require("source \"$release_file\"" not in release)

for command in ("GET", "SET", "GETDEL", "DEL", "EVAL"):
    require(command in verify)
require("reference-bff:production:portfolio:identity:verifier" in verify)
require("SELECT version_num FROM identity.alembic_version" in verify)

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
