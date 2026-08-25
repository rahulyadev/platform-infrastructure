#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd -- "$repository_root"

failures=0

fail() {
  printf 'COGNITO POLICY FAILURE: %s\n' "$1" >&2
  failures=$((failures + 1))
}

require_count() {
  local expected="$1"
  local pattern="$2"
  local file="$3"
  local message="$4"
  local actual

  actual="$(grep -Ec "$pattern" "$file" || true)"
  if [[ "$actual" != "$expected" ]]; then
    fail "$message"
  fi
}

reject_pattern() {
  local pattern="$1"
  local file="$2"
  local message="$3"

  if grep -Eq "$pattern" "$file"; then
    fail "$message"
  fi
}

module_root="infra/modules/identity_cognito_core"
module_main="$module_root/main.tf"
module_variables="$module_root/variables.tf"
module_outputs="$module_root/outputs.tf"
module_versions="$module_root/versions.tf"
core_main="infra/live/production/core/main.tf"
core_variables="infra/live/production/core/variables.tf"
core_outputs="infra/live/production/core/outputs.tf"
core_values="infra/live/production/core/production.tfvars"

required_files=(
  "$module_main"
  "$module_variables"
  "$module_outputs"
  "$module_versions"
  "$core_main"
  "$core_variables"
  "$core_outputs"
  "$core_values"
)
for file in "${required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    fail "required Cognito contract file is missing: $file"
  fi
done

if ((failures > 0)); then
  printf 'Cognito core policy checks failed before parsing.\n' >&2
  exit 1
fi

mapfile -t tofu_files < <(git ls-files --cached --others --exclude-standard -- '*.tf')
mapfile -t cognito_resource_files < <(
  grep -El '^[[:space:]]*resource[[:space:]]+"aws_cognito_' "${tofu_files[@]}" || true
)
if [[ "${#cognito_resource_files[@]}" != "1" || "${cognito_resource_files[0]:-}" != "$module_main" ]]; then
  fail "Cognito resources must exist only in the exact Identity Cognito core module"
fi

require_count 2 '^[[:space:]]*resource[[:space:]]+"aws_[^"]+"[[:space:]]+"[^"]+"[[:space:]]*\{' \
  "$module_main" "Identity Cognito core module must contain exactly two resources"
require_count 1 '^[[:space:]]*resource[[:space:]]+"aws_cognito_user_pool"[[:space:]]+"this"[[:space:]]*\{' \
  "$module_main" "Identity Cognito core module must contain one exact User Pool"
require_count 1 '^[[:space:]]*resource[[:space:]]+"aws_cognito_resource_server"[[:space:]]+"identity_api"[[:space:]]*\{' \
  "$module_main" "Identity Cognito core module must contain one exact resource server"
reject_pattern '^[[:space:]]*(data|module|provider)[[:space:]]+"' "$module_main" \
  "Identity Cognito core module must not contain data, child-module, or provider blocks"

require_count 1 '^[[:space:]]*user_pool_tier[[:space:]]*=[[:space:]]*"ESSENTIALS"[[:space:]]*$' \
  "$module_main" "User Pool must explicitly use the ESSENTIALS tier"
require_count 1 '^[[:space:]]*deletion_protection[[:space:]]*=[[:space:]]*"ACTIVE"[[:space:]]*$' \
  "$module_main" "User Pool deletion protection must be active"
require_count 1 '^[[:space:]]*prevent_destroy[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
  "$module_main" "User Pool must retain a source-backed prevent_destroy guard"
require_count 1 '^[[:space:]]*mfa_configuration[[:space:]]*=[[:space:]]*"OFF"[[:space:]]*$' \
  "$module_main" "User Pool MFA must remain explicitly off in the core scaffold"
require_count 1 '^[[:space:]]*allow_admin_create_user_only[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
  "$module_main" "User Pool creation must remain administrator-only"
require_count 1 '^[[:space:]]*name[[:space:]]*=[[:space:]]*"admin_only"[[:space:]]*$' \
  "$module_main" "User Pool recovery must remain administrator-only"
require_count 1 '^[[:space:]]*priority[[:space:]]*=[[:space:]]*1[[:space:]]*$' \
  "$module_main" "Administrator-only recovery must have the sole priority"
require_count 1 '^[[:space:]]*case_sensitive[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
  "$module_main" "Cognito usernames must remain case-sensitive"

require_count 1 '^[[:space:]]*schema[[:space:]]*\{[[:space:]]*$' \
  "$module_main" "User Pool must declare exactly one standard schema override"
require_count 1 '^[[:space:]]*attribute_data_type[[:space:]]*=[[:space:]]*"String"[[:space:]]*$' \
  "$module_main" "Email schema must remain a string"
require_count 1 '^[[:space:]]*developer_only_attribute[[:space:]]*=[[:space:]]*false[[:space:]]*$' \
  "$module_main" "Email schema must remain a standard attribute"
require_count 1 '^[[:space:]]*mutable[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
  "$module_main" "Email schema must remain mutable"
require_count 1 '^[[:space:]]*name[[:space:]]*=[[:space:]]*"email"[[:space:]]*$' \
  "$module_main" "Email must be the exact required standard attribute"
require_count 1 '^[[:space:]]*required[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
  "$module_main" "Email schema must remain required"
require_count 1 '^[[:space:]]*min_length[[:space:]]*=[[:space:]]*0[[:space:]]*$' \
  "$module_main" "Email schema minimum must retain the provider-stable standard bound"
require_count 1 '^[[:space:]]*max_length[[:space:]]*=[[:space:]]*2048[[:space:]]*$' \
  "$module_main" "Email schema maximum must retain the provider-stable standard bound"

require_count 1 '^[[:space:]]*minimum_length[[:space:]]*=[[:space:]]*16[[:space:]]*$' \
  "$module_main" "Native password policy must require at least 16 characters"
for requirement in require_lowercase require_numbers require_symbols require_uppercase; do
  require_count 1 "^[[:space:]]*$requirement[[:space:]]*=[[:space:]]*true[[:space:]]*$" \
    "$module_main" "Native password policy is missing $requirement"
done
require_count 1 '^[[:space:]]*temporary_password_validity_days[[:space:]]*=[[:space:]]*1[[:space:]]*$' \
  "$module_main" "Temporary native passwords must expire after one day"

for forbidden in \
  alias_attributes auto_verified_attributes email_configuration email_mfa_configuration \
  lambda_config password_history_size sign_in_policy sms_configuration \
  software_token_mfa_configuration user_pool_add_ons username_attributes \
  verification_message_template web_authn_configuration; do
  reject_pattern "^[[:space:]]*$forbidden([[:space:]]|=|\\{)" "$module_main" \
    "deferred or side-effecting User Pool setting is forbidden: $forbidden"
done
require_count 1 '^[[:space:]]*tags[[:space:]]*=[[:space:]]*var[.]tags[[:space:]]*$' \
  "$module_main" "Canonical tags must be applied only to the supported User Pool"

require_count 1 '^[[:space:]]*identifier[[:space:]]*=[[:space:]]*local[.]resource_server_identifier[[:space:]]*$' \
  "$module_main" "Resource server must use the fixed Identity API identifier"
require_count 1 '^[[:space:]]*resource_server_identifier[[:space:]]*=[[:space:]]*"identity-service://api"[[:space:]]*$' \
  "$module_main" "Identity API resource identifier must remain exact"
require_count 1 '^[[:space:]]*name[[:space:]]*=[[:space:]]*"Identity service API"[[:space:]]*$' \
  "$module_main" "Resource server display name must remain domain-neutral and exact"
require_count 1 '^[[:space:]]*user_pool_id[[:space:]]*=[[:space:]]*aws_cognito_user_pool[.]this[.]id[[:space:]]*$' \
  "$module_main" "Resource server must attach to the module User Pool"
require_count 2 '^[[:space:]]*scope[[:space:]]*\{[[:space:]]*$' \
  "$module_main" "Resource server must define exactly two OAuth scopes"
require_count 1 '^[[:space:]]*scope_name[[:space:]]*=[[:space:]]*"profile[.]read"[[:space:]]*$' \
  "$module_main" "Resource server profile.read scope must remain exact"
require_count 1 '^[[:space:]]*scope_name[[:space:]]*=[[:space:]]*"profile[.]write"[[:space:]]*$' \
  "$module_main" "Resource server profile.write scope must remain exact"
require_count 1 '^[[:space:]]*profile_read_scope_identifier[[:space:]]*=[[:space:]]*"[$][{]local[.]resource_server_identifier[}]/profile[.]read"[[:space:]]*$' \
  "$module_main" "Fully qualified profile.read identifier must remain exact"
require_count 1 '^[[:space:]]*profile_write_scope_identifier[[:space:]]*=[[:space:]]*"[$][{]local[.]resource_server_identifier[}]/profile[.]write"[[:space:]]*$' \
  "$module_main" "Fully qualified profile.write identifier must remain exact"

expected_module_outputs=(
  profile_read_scope_identifier
  profile_write_scope_identifier
  resource_server_identifier
  user_pool_arn
  user_pool_endpoint
  user_pool_id
)
mapfile -t actual_module_outputs < <(
  sed -n 's/^output "\([^"]*\)" {.*/\1/p' "$module_outputs" | sort
)
if [[ "$(printf '%s\n' "${actual_module_outputs[@]}")" != "$(printf '%s\n' "${expected_module_outputs[@]}")" ]]; then
  fail "module outputs must be exactly the six non-secret pool and resource/scope identifiers"
fi
reject_pattern '^[[:space:]]*sensitive[[:space:]]*=[[:space:]]*true' "$module_outputs" \
  "Cognito core contract outputs must remain non-secret"
reject_pattern '(client|domain|provider|secret)' "$module_outputs" \
  "module outputs must not expose deferred client, domain, provider, or secret values"

expected_module_variables=(name_prefix tags)
mapfile -t actual_module_variables < <(
  sed -n 's/^variable "\([^"]*\)" {.*/\1/p' "$module_variables" | sort
)
if [[ "$(printf '%s\n' "${actual_module_variables[@]}")" != "$(printf '%s\n' "${expected_module_variables[@]}")" ]]; then
  fail "module inputs must remain limited to name_prefix and canonical tags"
fi

require_count 1 '^[[:space:]]*variable[[:space:]]+"enable_identity_cognito_core"[[:space:]]*\{' \
  "$core_variables" "production core must declare one explicit Cognito feature gate"
require_count 1 '^[[:space:]]*default[[:space:]]*=[[:space:]]*false[[:space:]]*$' \
  "$core_variables" "production Cognito feature gate must default to false"
require_count 1 '^[[:space:]]*module[[:space:]]+"identity_cognito_core"[[:space:]]*\{' \
  "$core_main" "production core must reference the Cognito core module exactly once"
require_count 1 '^[[:space:]]*count[[:space:]]*=[[:space:]]*var[.]enable_identity_cognito_core[[:space:]]*[?][[:space:]]*1[[:space:]]*:[[:space:]]*0[[:space:]]*$' \
  "$core_main" "production Cognito module must use only the explicit boolean gate"
require_count 1 '^[[:space:]]*source[[:space:]]*=[[:space:]]*"[.][.]/[.][.]/[.][.]/modules/identity_cognito_core"[[:space:]]*$' \
  "$core_main" "production Cognito module source must remain exact"
reject_pattern 'enable_identity_cognito_core' "$core_values" \
  "committed production values must not enable or override the default-false Cognito gate"

root_output_names=(
  identity_cognito_user_pool_id
  identity_cognito_user_pool_arn
  identity_cognito_user_pool_endpoint
  identity_cognito_resource_server_identifier
  identity_cognito_profile_read_scope_identifier
  identity_cognito_profile_write_scope_identifier
)
for output_name in "${root_output_names[@]}"; do
  require_count 1 "^output[[:space:]]+\"$output_name\"[[:space:]]*\\{" \
    "$core_outputs" "production core output is missing or duplicated: $output_name"
done
require_count 6 '^[[:space:]]*value[[:space:]]*=[[:space:]]*var[.]enable_identity_cognito_core[[:space:]]*[?].*:[[:space:]]*null[[:space:]]*$' \
  "$core_outputs" "all Cognito root outputs must be null when the feature gate is disabled"

deferred_resource_pattern='^[[:space:]]*resource[[:space:]]+"(aws_cognito_user_pool_client|aws_cognito_identity_provider|aws_cognito_user_pool_domain|aws_cognito_identity_pool|aws_acm_certificate)"'
if grep -El "$deferred_resource_pattern" "${tofu_files[@]}" >/dev/null; then
  fail "deferred app-client, IdP, domain, Identity Pool, or certificate resource is present"
fi

if ((failures > 0)); then
  printf 'Cognito core policy checks failed with %d violation(s).\n' "$failures" >&2
  exit 1
fi

printf 'Cognito core policy checks passed.\n'
