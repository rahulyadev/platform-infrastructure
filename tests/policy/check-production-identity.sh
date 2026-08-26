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

core_values=infra/live/production/core/production.tfvars
core_variables=infra/live/production/core/variables.tf
core_outputs=infra/live/production/core/outputs.tf
runtime_values=infra/live/production/runtime/runtime.tfvars
runtime_variables=infra/live/production/runtime/variables.tf
runtime_outputs=infra/live/production/runtime/outputs.tf
authentication=infra/modules/identity_authentication/main.tf
custody=infra/modules/identity_secret_custody/main.tf
production_module=infra/modules/identity_production
compose=config/runtime/identity-compose.yml.tftpl
images=config/runtime/identity-images.json
nginx=config/nginx/identity-runtime.conf.tftpl
pgbackrest=config/runtime/pgbackrest.conf.tftpl
production_document=docs/production-identity.md

for file in "$core_values" "$core_variables" "$core_outputs" "$runtime_values" "$runtime_variables" \
  "$runtime_outputs" "$authentication" "$custody" "$production_module/ecr.tf" \
  "$production_module/github_oidc.tf" "$production_module/iam.tf" \
  "$production_module/documents.tf" "$production_module/monitoring.tf" "$compose" "$images" "$nginx" "$pgbackrest" "$production_document"; do
  [[ -f "$file" ]] || fail "a required production Identity source file is missing"
done
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
require_fixed "$core_variables" 'var.identity_reference_bff_application_origins == [format("https://%s", var.base_domain)]' \
  "the confidential client must require the exact portfolio origin"
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
require_fixed "$authentication" 'provider_name = "Google"' \
  "the sole Cognito identity provider must be Google"
reject 'resource "aws_route53|"(COGNITO|Facebook|LoginWithAmazon|SignInWithApple|SAML)"' "$authentication" \
  "authentication source must not manage DNS or add another identity provider"

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
require_fixed "$production_module/github_oidc.tf" 'repo:${var.github_owner}/${var.github_repository}:environment:${var.github_environment}' \
  "Identity deployment trust must remain environment-scoped"
require_fixed "$production_module/github_oidc.tf" 'token.actions.githubusercontent.com:repository_owner_id' \
  "deployment trust must bind the immutable owner ID"
require_fixed "$production_module/github_oidc.tf" 'token.actions.githubusercontent.com:repository_id' \
  "deployment trust must bind the immutable repository ID"
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
require_fixed deploy/ssm/enable-identity-tls.sh 'identity.rahuly.in' \
  "the fixed Identity TLS operation must target only the exact API hostname"
require_fixed "$production_module/documents.tf" 'schedule_expression         = "rate(30 minutes)"' \
  "Identity verification must run on the exact supported thirty-minute schedule"
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
