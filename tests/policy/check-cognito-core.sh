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

require_fixed_count() {
  local expected="$1"
  local needle="$2"
  local file="$3"
  local message="$4"
  local actual

  actual="$(grep -Fc -- "$needle" "$file" || true)"
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

require_aggregate_count() {
  local expected="$1"
  local pattern="$2"
  local message="$3"
  shift 3

  local actual=0
  local count
  local file

  for file in "$@"; do
    count="$(grep -Ec "$pattern" "$file" || true)"
    actual=$((actual + count))
  done

  if [[ "$actual" != "$expected" ]]; then
    fail "$message"
  fi
}

reject_aggregate_pattern() {
  local pattern="$1"
  local message="$2"
  shift 2

  local file

  for file in "$@"; do
    if grep -Eq "$pattern" "$file"; then
      fail "$message"
      return
    fi
  done
}

require_text_count() {
  local expected="$1"
  local pattern="$2"
  local text="$3"
  local message="$4"
  local actual

  actual="$(grep -Ec "$pattern" <<<"$text" || true)"
  if [[ "$actual" != "$expected" ]]; then
    fail "$message"
  fi
}

module_root="infra/modules/identity_cognito_core"
module_main="$module_root/main.tf"
module_variables="$module_root/variables.tf"
module_outputs="$module_root/outputs.tf"
module_versions="$module_root/versions.tf"
client_module_root="infra/modules/identity_cognito_reference_bff_client"
client_module_main="$client_module_root/main.tf"
client_module_variables="$client_module_root/variables.tf"
client_module_outputs="$client_module_root/outputs.tf"
client_module_versions="$client_module_root/versions.tf"
authentication_module_root="infra/modules/identity_authentication"
authentication_module_main="$authentication_module_root/main.tf"
core_main="infra/live/production/core/main.tf"
core_variables="infra/live/production/core/variables.tf"
core_outputs="infra/live/production/core/outputs.tf"
core_values="infra/live/production/core/production.tfvars"

required_files=(
  "$module_main"
  "$module_variables"
  "$module_outputs"
  "$module_versions"
  "$client_module_main"
  "$client_module_variables"
  "$client_module_outputs"
  "$client_module_versions"
  "$core_main"
  "$core_variables"
  "$core_outputs"
  "$core_values"
  "$authentication_module_main"
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
module_tofu_files=()
client_module_tofu_files=()
for file in "${tofu_files[@]}"; do
  if [[ "$file" == "$module_root/"*.tf && "${file#"$module_root/"}" != */* ]]; then
    module_tofu_files+=("$file")
  fi
  if [[ "$file" == "$client_module_root/"*.tf && "${file#"$client_module_root/"}" != */* ]]; then
    client_module_tofu_files+=("$file")
  fi
done

resource_block_pattern='^[[:space:]]*resource[[:space:]]+"[^"]+"[[:space:]]+"[^"]+"[[:space:]]*\{'
cognito_resource_block_pattern='^[[:space:]]*resource[[:space:]]+"aws_cognito_[^"]+"[[:space:]]+"[^"]+"[[:space:]]*\{'
user_pool_block_pattern='^[[:space:]]*resource[[:space:]]+"aws_cognito_user_pool"[[:space:]]+"this"[[:space:]]*\{'
resource_server_block_pattern='^[[:space:]]*resource[[:space:]]+"aws_cognito_resource_server"[[:space:]]+"identity_api"[[:space:]]*\{'
client_block_pattern='^[[:space:]]*resource[[:space:]]+"aws_cognito_user_pool_client"[[:space:]]+"reference_bff"[[:space:]]*\{'
google_provider_block_pattern='^[[:space:]]*resource[[:space:]]+"aws_cognito_identity_provider"[[:space:]]+"google"[[:space:]]*\{'
domain_block_pattern='^[[:space:]]*resource[[:space:]]+"aws_cognito_user_pool_domain"[[:space:]]+"auth"[[:space:]]*\{'

require_aggregate_count 2 "$resource_block_pattern" \
  "Identity Cognito core module must contain exactly two resource blocks across all module files" \
  "${module_tofu_files[@]}"
require_aggregate_count 1 "$user_pool_block_pattern" \
  "Identity Cognito core module must contain exactly aws_cognito_user_pool.this once" \
  "${module_tofu_files[@]}"
require_aggregate_count 1 "$resource_server_block_pattern" \
  "Identity Cognito core module must contain exactly aws_cognito_resource_server.identity_api once" \
  "${module_tofu_files[@]}"
reject_aggregate_pattern '^[[:space:]]*(data|module|provider)[[:space:]]+"' \
  "Identity Cognito core module files must not contain data, child-module, or provider blocks" \
  "${module_tofu_files[@]}"

require_aggregate_count 1 "$resource_block_pattern" \
  "reference BFF Cognito client module must contain exactly one resource block across all module files" \
  "${client_module_tofu_files[@]}"
require_aggregate_count 1 "$client_block_pattern" \
  "reference BFF Cognito client module must contain exactly aws_cognito_user_pool_client.reference_bff once" \
  "${client_module_tofu_files[@]}"
reject_aggregate_pattern '^[[:space:]]*(data|module|provider|import|moved|check)[[:space:]]+("|\{)' \
  "reference BFF Cognito client module must not contain data, child-module, provider, import, moved, or check blocks" \
  "${client_module_tofu_files[@]}"
reject_aggregate_pattern '^[[:space:]]*provisioner[[:space:]]+"' \
  "reference BFF Cognito client module must not contain provisioners" \
  "${client_module_tofu_files[@]}"

require_aggregate_count 5 "$cognito_resource_block_pattern" \
  "repository must contain exactly the five approved Cognito resource blocks" \
  "${tofu_files[@]}"
require_aggregate_count 1 "$user_pool_block_pattern" \
  "repository must contain exactly one approved Cognito User Pool block" \
  "${tofu_files[@]}"
require_aggregate_count 1 "$resource_server_block_pattern" \
  "repository must contain exactly one approved Cognito resource server block" \
  "${tofu_files[@]}"
require_aggregate_count 1 "$client_block_pattern" \
  "repository must contain exactly one approved reference BFF Cognito app-client block" \
  "${tofu_files[@]}"
require_aggregate_count 1 "$google_provider_block_pattern" \
  "repository must contain exactly one approved Google Cognito identity-provider block" \
  "${tofu_files[@]}"
require_aggregate_count 1 "$domain_block_pattern" \
  "repository must contain exactly one approved Cognito custom-domain block" \
  "${tofu_files[@]}"
reject_aggregate_pattern '^[[:space:]]*data[[:space:]]+"aws_cognito_[^"]+"' \
  "repository must not contain Cognito data blocks" \
  "${tofu_files[@]}"

for file in "${tofu_files[@]}"; do
  if ! grep -Eq 'aws_cognito_' "$file"; then
    continue
  fi

  approved_cognito_file=false
  if [[ "$file" == "$module_root/"*.tf && "${file#"$module_root/"}" != */* ]]; then
    approved_cognito_file=true
  fi
  if [[ "$file" == "$client_module_root/"*.tf && "${file#"$client_module_root/"}" != */* ]]; then
    approved_cognito_file=true
  fi
  if [[ "$file" == "$authentication_module_root/"*.tf && "${file#"$authentication_module_root/"}" != */* ]]; then
    approved_cognito_file=true
  fi

  if [[ "$approved_cognito_file" != true ]]; then
    fail "Cognito provider references must remain inside the three exact approved Cognito module directories"
    break
  fi
done

mapfile -t cognito_resource_files < <(
  grep -El '^[[:space:]]*resource[[:space:]]+"aws_cognito_' "${tofu_files[@]}" || true
)
mapfile -t expected_cognito_resource_files < <(printf '%s\n' "$module_main" "$client_module_main" "$authentication_module_main" | sort)
mapfile -t cognito_resource_files < <(printf '%s\n' "${cognito_resource_files[@]}" | sort)
if [[ "$(printf '%s\n' "${cognito_resource_files[@]}")" != "$(printf '%s\n' "${expected_cognito_resource_files[@]}")" ]]; then
  fail "Cognito resources must exist only in the exact three approved module main files"
fi

require_count 2 '^[[:space:]]*resource[[:space:]]+"aws_[^"]+"[[:space:]]+"[^"]+"[[:space:]]*\{' \
  "$module_main" "Identity Cognito core module must contain exactly two resources"
require_count 1 '^[[:space:]]*resource[[:space:]]+"aws_cognito_user_pool"[[:space:]]+"this"[[:space:]]*\{' \
  "$module_main" "Identity Cognito core module must contain one exact User Pool"
require_count 1 '^[[:space:]]*resource[[:space:]]+"aws_cognito_resource_server"[[:space:]]+"identity_api"[[:space:]]*\{' \
  "$module_main" "Identity Cognito core module must contain one exact resource server"
reject_pattern '^[[:space:]]*(data|module|provider)[[:space:]]+"' "$module_main" \
  "Identity Cognito core module must not contain data, child-module, or provider blocks"

require_count 1 '^[[:space:]]*resource[[:space:]]+"aws_[^"]+"[[:space:]]+"[^"]+"[[:space:]]*\{' \
  "$client_module_main" "reference BFF Cognito client module must contain exactly one resource"
require_count 1 "$client_block_pattern" \
  "$client_module_main" "reference BFF Cognito client module must contain one exact app client"
reject_pattern '^[[:space:]]*(data|module|provider|import|moved|check)[[:space:]]+("|\{)' "$client_module_main" \
  "reference BFF Cognito client module must not contain data, child-module, provider, import, moved, or check blocks"
reject_pattern '^[[:space:]]*provisioner[[:space:]]+"' "$client_module_main" \
  "reference BFF Cognito client module must not contain provisioners"

require_single_normalized_module_source() {
  local inspected_module_root="$1"
  local contract_name="$2"
  local module_absolute
  local source_absolute
  local source_count=0
  local source_file=""
  local source_value
  local file

  module_absolute="$(realpath -m -- "$repository_root/$inspected_module_root")"
  for file in "${tofu_files[@]}"; do
    while IFS= read -r source_value; do
      if [[ "$source_value" != /* && "$source_value" != ./* && "$source_value" != ../* ]]; then
        continue
      fi

      if [[ "$source_value" == /* ]]; then
        source_absolute="$(realpath -m -- "$source_value")"
      else
        source_absolute="$(realpath -m -- "$repository_root/$(dirname -- "$file")/$source_value")"
      fi

      if [[ "$source_absolute" == "$module_absolute" ]]; then
        source_count=$((source_count + 1))
        source_file="$file"
      fi
    done < <(
      sed -nE 's/^[[:space:]]*source[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*$/\1/p' "$file"
    )
  done

  if [[ "$source_count" != "1" ]]; then
    fail "repository must contain exactly one normalized local source reference to $contract_name"
  elif [[ "$source_file" != "$core_main" ]]; then
    fail "$contract_name source reference must exist only in production core main.tf"
  fi
}

require_single_normalized_module_source "$module_root" "the Identity Cognito core module"
require_single_normalized_module_source "$client_module_root" "the reference BFF Cognito client module"

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

require_count 1 '^[[:space:]]*name[[:space:]]*=[[:space:]]*"[$][{]var[.]name_prefix[}]-reference-bff"[[:space:]]*$' \
  "$client_module_main" "reference BFF app-client name must remain canonical and exact"
require_count 1 '^[[:space:]]*user_pool_id[[:space:]]*=[[:space:]]*var[.]user_pool_id[[:space:]]*$' \
  "$client_module_main" "reference BFF app client must use only the supplied existing User Pool ID"
require_count 1 '^[[:space:]]*generate_secret[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
  "$client_module_main" "reference BFF app client must remain confidential"
require_count 1 '^[[:space:]]*allowed_oauth_flows_user_pool_client[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
  "$client_module_main" "reference BFF app client must enable User Pool OAuth flows"
require_count 1 '^[[:space:]]*allowed_oauth_flows[[:space:]]*=[[:space:]]*\["code"\][[:space:]]*$' \
  "$client_module_main" "reference BFF app client must permit only the authorization-code OAuth flow"
require_count 1 '^[[:space:]]*allowed_oauth_flows[[:space:]]*=' \
  "$client_module_main" "reference BFF app client must contain exactly one OAuth-flow assignment"
require_count 1 '^[[:space:]]*allowed_oauth_scopes[[:space:]]*=[[:space:]]*\[[[:space:]]*$' \
  "$client_module_main" "reference BFF app client must declare the exact reviewed OAuth scope set"
require_count 1 '^[[:space:]]*"openid",[[:space:]]*$' \
  "$client_module_main" "reference BFF app client must request openid exactly once"
require_count 1 '^[[:space:]]*var[.]profile_read_scope_identifier,[[:space:]]*$' \
  "$client_module_main" "reference BFF app client must request the reviewed profile-read scope exactly once"
require_count 1 '^[[:space:]]*var[.]profile_write_scope_identifier,[[:space:]]*$' \
  "$client_module_main" "reference BFF app client must request the reviewed profile-write scope exactly once"
require_count 1 '^[[:space:]]*supported_identity_providers[[:space:]]*=[[:space:]]*\["Google"\][[:space:]]*$' \
  "$client_module_main" "reference BFF app client must support only Google"
require_count 1 '^[[:space:]]*explicit_auth_flows[[:space:]]*=[[:space:]]*\[\][[:space:]]*$' \
  "$client_module_main" "reference BFF app client must disable every native and API authentication flow"

require_count 1 '^[[:space:]]*callback_urls[[:space:]]*=[[:space:]]*local[.]callback_urls[[:space:]]*$' \
  "$client_module_main" "reference BFF callback URLs must use only the validated derived callback set"
require_count 1 '^[[:space:]]*logout_urls[[:space:]]*=[[:space:]]*local[.]logout_urls[[:space:]]*$' \
  "$client_module_main" "reference BFF logout URLs must use only the validated derived logout set"
require_count 1 '^[[:space:]]*for[[:space:]]+origin[[:space:]]+in[[:space:]]+var[.]application_origins[[:space:]]*:[[:space:]]*"[$][{]origin[}]/auth/callback"[[:space:]]*$' \
  "$client_module_main" "reference BFF callbacks must derive only the exact /auth/callback path"
require_count 1 '^[[:space:]]*for[[:space:]]+origin[[:space:]]+in[[:space:]]+var[.]application_origins[[:space:]]*:[[:space:]]*"[$][{]origin[}]/auth/signed-out"[[:space:]]*$' \
  "$client_module_main" "reference BFF logout URLs must derive only the exact /auth/signed-out path"
reject_pattern '^[[:space:]]*default_redirect_uri[[:space:]]*=' "$client_module_main" \
  "reference BFF app client must not declare a default redirect URI"

require_count 1 '^[[:space:]]*access_token_validity[[:space:]]*=[[:space:]]*15[[:space:]]*$' \
  "$client_module_main" "reference BFF access tokens must remain valid for exactly 15 minutes"
require_count 1 '^[[:space:]]*id_token_validity[[:space:]]*=[[:space:]]*15[[:space:]]*$' \
  "$client_module_main" "reference BFF ID tokens must remain valid for exactly 15 minutes"
require_count 1 '^[[:space:]]*refresh_token_validity[[:space:]]*=[[:space:]]*14[[:space:]]*$' \
  "$client_module_main" "reference BFF refresh tokens must remain valid for exactly 14 days"
require_count 1 '^[[:space:]]*token_validity_units[[:space:]]*\{[[:space:]]*$' \
  "$client_module_main" "reference BFF app client must declare explicit token validity units"
require_count 1 '^[[:space:]]*access_token[[:space:]]*=[[:space:]]*"minutes"[[:space:]]*$' \
  "$client_module_main" "reference BFF access-token validity unit must be minutes"
require_count 1 '^[[:space:]]*id_token[[:space:]]*=[[:space:]]*"minutes"[[:space:]]*$' \
  "$client_module_main" "reference BFF ID-token validity unit must be minutes"
require_count 1 '^[[:space:]]*refresh_token[[:space:]]*=[[:space:]]*"days"[[:space:]]*$' \
  "$client_module_main" "reference BFF refresh-token validity unit must be days"
require_count 1 '^[[:space:]]*refresh_token_rotation[[:space:]]*\{[[:space:]]*$' \
  "$client_module_main" "reference BFF app client must configure refresh-token rotation"
require_count 1 '^[[:space:]]*feature[[:space:]]*=[[:space:]]*"ENABLED"[[:space:]]*$' \
  "$client_module_main" "reference BFF refresh-token rotation must remain enabled"
require_count 1 '^[[:space:]]*retry_grace_period_seconds[[:space:]]*=[[:space:]]*10[[:space:]]*$' \
  "$client_module_main" "reference BFF refresh-token retry grace must remain exactly 10 seconds"

require_count 1 '^[[:space:]]*enable_token_revocation[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
  "$client_module_main" "reference BFF app client must retain token revocation"
require_count 1 '^[[:space:]]*prevent_user_existence_errors[[:space:]]*=[[:space:]]*"ENABLED"[[:space:]]*$' \
  "$client_module_main" "reference BFF app client must prevent user-existence errors"
require_count 1 '^[[:space:]]*auth_session_validity[[:space:]]*=[[:space:]]*3[[:space:]]*$' \
  "$client_module_main" "reference BFF authentication sessions must remain valid for exactly three minutes"
require_count 1 '^[[:space:]]*read_attributes[[:space:]]*=[[:space:]]*\["email",[[:space:]]*"email_verified"\][[:space:]]*$' \
  "$client_module_main" "reference BFF readable attributes must remain exactly email and email_verified"
require_count 1 '^[[:space:]]*write_attributes[[:space:]]*=[[:space:]]*\["email"\][[:space:]]*$' \
  "$client_module_main" "reference BFF writable attributes must remain exactly email"
require_count 1 '^[[:space:]]*prevent_destroy[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
  "$client_module_main" "reference BFF app client must retain a source-backed prevent_destroy guard"

for forbidden_client_setting in \
  analytics_configuration default_redirect_uri enable_propagate_additional_user_context_data \
  user_data_shared; do
  reject_pattern "^[[:space:]]*$forbidden_client_setting([[:space:]]|=|\\{)" "$client_module_main" \
    "deferred or side-effecting reference BFF app-client setting is forbidden: $forbidden_client_setting"
done
reject_pattern 'https://' "$client_module_main" \
  "reference BFF app-client resource must not contain a committed application origin"

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

expected_client_module_outputs=(callback_urls client_id client_secret logout_urls)
mapfile -t actual_client_module_outputs < <(
  sed -n 's/^output "\([^"]*\)" {.*/\1/p' "$client_module_outputs" | sort
)
if [[ "$(printf '%s\n' "${actual_client_module_outputs[@]}")" != "$(printf '%s\n' "${expected_client_module_outputs[@]}")" ]]; then
  fail "reference BFF client module outputs must be exactly client_id, callback_urls, logout_urls, and client_secret"
fi
require_count 1 '^[[:space:]]*value[[:space:]]*=[[:space:]]*aws_cognito_user_pool_client[.]reference_bff[.]id[[:space:]]*$' \
  "$client_module_outputs" "reference BFF client_id output must use only the managed app-client ID"
require_count 1 '^[[:space:]]*value[[:space:]]*=[[:space:]]*local[.]callback_urls[[:space:]]*$' \
  "$client_module_outputs" "reference BFF callback_urls output must expose only the derived callback set"
require_count 1 '^[[:space:]]*value[[:space:]]*=[[:space:]]*local[.]logout_urls[[:space:]]*$' \
  "$client_module_outputs" "reference BFF logout_urls output must expose only the derived logout set"
require_count 1 '^[[:space:]]*value[[:space:]]*=[[:space:]]*aws_cognito_user_pool_client[.]reference_bff[.]client_secret[[:space:]]*$' \
  "$client_module_outputs" "reference BFF client_secret output must use only the managed app-client secret"
require_count 1 '^[[:space:]]*sensitive[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
  "$client_module_outputs" "reference BFF client_secret child output must be sensitive"
client_secret_output_block="$(
  sed -n \
    '/^[[:space:]]*output[[:space:]]*"client_secret"[[:space:]]*{[[:space:]]*$/,/^[[:space:]]*}[[:space:]]*$/p' \
    "$client_module_outputs"
)"
require_text_count 1 '^[[:space:]]*sensitive[[:space:]]*=[[:space:]]*true[[:space:]]*$' \
  "$client_secret_output_block" "only the reference BFF client_secret output may carry the required sensitive marker"

expected_client_module_variables=(
  application_origins
  name_prefix
  profile_read_scope_identifier
  profile_write_scope_identifier
  user_pool_id
)
mapfile -t actual_client_module_variables < <(
  sed -n 's/^variable "\([^"]*\)" {.*/\1/p' "$client_module_variables" | sort
)
if [[ "$(printf '%s\n' "${actual_client_module_variables[@]}")" != "$(printf '%s\n' "${expected_client_module_variables[@]}")" ]]; then
  fail "reference BFF client inputs must remain limited to the pool, scopes, name prefix, and application origins"
fi
require_count 1 'var[.]profile_read_scope_identifier[[:space:]]*==[[:space:]]*"identity-service://api/profile[.]read"' \
  "$client_module_variables" "reference BFF profile-read scope input must validate the exact reviewed identifier"
require_count 1 'var[.]profile_write_scope_identifier[[:space:]]*==[[:space:]]*"identity-service://api/profile[.]write"' \
  "$client_module_variables" "reference BFF profile-write scope input must validate the exact reviewed identifier"
require_count 1 'length[(]var[.]application_origins[)][[:space:]]*>=[[:space:]]*1' \
  "$client_module_variables" "reference BFF client module must require at least one application origin"
require_count 1 'length[(]var[.]application_origins[)][[:space:]]*<=[[:space:]]*4' \
  "$client_module_variables" "reference BFF client module must permit no more than four application origins"
require_count 1 'length[(]distinct[(]var[.]application_origins[)][)][[:space:]]*==[[:space:]]*length[(]var[.]application_origins[)]' \
  "$client_module_variables" "reference BFF client module must reject duplicate application origins"
require_count 1 'origin[[:space:]]*==[[:space:]]*lower[(]origin[)]' \
  "$client_module_variables" "reference BFF client module must require lowercase application origins"
require_count 1 'length[(]origin[)][[:space:]]*<=[[:space:]]*261' \
  "$client_module_variables" "reference BFF client module must bound application-origin length"
require_count 1 'can[(]regex[(]"[\^]https://[(][[]a-z0-9[]]' \
  "$client_module_variables" "reference BFF client module must validate exact HTTPS DNS origins"
require_fixed_count 1 'can(regex("^https://([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", origin))' \
  "$client_module_variables" "reference BFF client module must retain the exact HTTPS DNS-origin grammar"

require_count 1 '^[[:space:]]*variable[[:space:]]+"enable_identity_cognito_core"[[:space:]]*\{' \
  "$core_variables" "production core must declare one explicit Cognito feature gate"
identity_cognito_core_gate_block="$(
  sed -n \
    '/^[[:space:]]*variable[[:space:]]*"enable_identity_cognito_core"[[:space:]]*{[[:space:]]*$/,/^[[:space:]]*}[[:space:]]*$/p' \
    "$core_variables"
)"
require_text_count 1 '^[[:space:]]*default[[:space:]]*=[[:space:]]*false[[:space:]]*$' \
  "$identity_cognito_core_gate_block" "production Cognito core feature gate must default to false"
require_count 1 '^[[:space:]]*module[[:space:]]+"identity_cognito_core"[[:space:]]*\{' \
  "$core_main" "production core must reference the Cognito core module exactly once"
require_count 1 '^[[:space:]]*count[[:space:]]*=[[:space:]]*var[.]enable_identity_cognito_core[[:space:]]*[?][[:space:]]*1[[:space:]]*:[[:space:]]*0[[:space:]]*$' \
  "$core_main" "production Cognito module must use only the explicit boolean gate"
require_count 1 '^[[:space:]]*source[[:space:]]*=[[:space:]]*"[.][.]/[.][.]/[.][.]/modules/identity_cognito_core"[[:space:]]*$' \
  "$core_main" "production Cognito module source must remain exact"
identity_cognito_core_block="$(
  sed -n \
    '/^[[:space:]]*module[[:space:]]*"identity_cognito_core"[[:space:]]*{[[:space:]]*$/,/^[[:space:]]*}[[:space:]]*$/p' \
    "$core_main"
)"
require_text_count 4 '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*=' \
  "$identity_cognito_core_block" "production Cognito module must contain exactly count, source, and two approved inputs"
require_text_count 1 '^[[:space:]]*count[[:space:]]*=[[:space:]]*var[.]enable_identity_cognito_core[[:space:]]*[?][[:space:]]*1[[:space:]]*:[[:space:]]*0[[:space:]]*$' \
  "$identity_cognito_core_block" "production Cognito module block must retain the exact default-false count gate"
require_text_count 1 '^[[:space:]]*source[[:space:]]*=[[:space:]]*"[.][.]/[.][.]/[.][.]/modules/identity_cognito_core"[[:space:]]*$' \
  "$identity_cognito_core_block" "production Cognito module block must retain the exact local source"
require_text_count 1 '^[[:space:]]*name_prefix[[:space:]]*=[[:space:]]*local[.]name_prefix[[:space:]]*$' \
  "$identity_cognito_core_block" "production Cognito module block must retain the exact name_prefix input"
require_text_count 1 '^[[:space:]]*tags[[:space:]]*=[[:space:]]*local[.]default_tags[[:space:]]*$' \
  "$identity_cognito_core_block" "production Cognito module block must retain the exact canonical tags input"

require_count 1 '^[[:space:]]*variable[[:space:]]+"enable_identity_reference_bff_client"[[:space:]]*\{' \
  "$core_variables" "production core must declare one explicit reference BFF client feature gate"
identity_reference_bff_client_gate_block="$(
  sed -n \
    '/^[[:space:]]*variable[[:space:]]*"enable_identity_reference_bff_client"[[:space:]]*{[[:space:]]*$/,/^[[:space:]]*}[[:space:]]*$/p' \
    "$core_variables"
)"
require_text_count 1 '^[[:space:]]*default[[:space:]]*=[[:space:]]*false[[:space:]]*$' \
  "$identity_reference_bff_client_gate_block" "production reference BFF client feature gate must default to false"
require_text_count 1 '^[[:space:]]*condition[[:space:]]*=[[:space:]]*!var[.]enable_identity_reference_bff_client[[:space:]]*[|][|][[:space:]]*[(][[:space:]]*$' \
  "$identity_reference_bff_client_gate_block" "production reference BFF client gate must retain its fail-closed prerequisite validation"
require_text_count 1 '^[[:space:]]*var[.]enable_identity_cognito_core[[:space:]]*&&[[:space:]]*$' \
  "$identity_reference_bff_client_gate_block" "production reference BFF client gate must require the Cognito core gate"
require_text_count 1 '^[[:space:]]*var[.]enable_identity_google_federation[[:space:]]*&&[[:space:]]*$' \
  "$identity_reference_bff_client_gate_block" "production reference BFF client gate must require Google federation"
require_text_count 1 '^[[:space:]]*var[.]enable_identity_auth_domain[[:space:]]*&&[[:space:]]*$' \
  "$identity_reference_bff_client_gate_block" "production reference BFF client gate must require the custom domain"
require_fixed_count 1 'var.identity_reference_bff_application_origins == [format("https://%s", var.base_domain)]' \
  "$core_variables" "production reference BFF client gate must require the exact portfolio origin"
require_count 1 '^[[:space:]]*variable[[:space:]]+"identity_reference_bff_application_origins"[[:space:]]*\{' \
  "$core_variables" "production core must declare one reference BFF application-origin input"
identity_reference_bff_origins_block="$(
  sed -n \
    '/^[[:space:]]*variable[[:space:]]*"identity_reference_bff_application_origins"[[:space:]]*{[[:space:]]*$/,/^[[:space:]]*}[[:space:]]*$/p' \
    "$core_variables"
)"
require_text_count 1 '^[[:space:]]*default[[:space:]]*=[[:space:]]*\[\][[:space:]]*$' \
  "$identity_reference_bff_origins_block" "production reference BFF application origins must default to an empty list"
require_count 1 'length[(]var[.]identity_reference_bff_application_origins[)][[:space:]]*<=[[:space:]]*4' \
  "$core_variables" "production reference BFF application origins must permit no more than four values"
require_count 1 'length[(]distinct[(]var[.]identity_reference_bff_application_origins[)][)][[:space:]]*==[[:space:]]*length[(]var[.]identity_reference_bff_application_origins[)]' \
  "$core_variables" "production reference BFF application origins must reject duplicates"
require_count 1 'origin[[:space:]]*==[[:space:]]*lower[(]origin[)]' \
  "$core_variables" "production reference BFF application origins must remain lowercase"
require_count 1 'length[(]origin[)][[:space:]]*<=[[:space:]]*261' \
  "$core_variables" "production reference BFF application origins must retain the reviewed length bound"
require_fixed_count 1 'can(regex("^https://([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", origin))' \
  "$core_variables" "production reference BFF application origins must retain the exact HTTPS DNS-origin grammar"
reject_pattern '"https://[a-z0-9]' "$core_variables" \
  "production core variables must not contain a committed reference BFF origin"

require_count 1 '^[[:space:]]*module[[:space:]]+"identity_cognito_reference_bff_client"[[:space:]]*\{' \
  "$core_main" "production core must reference the reference BFF client module exactly once"
identity_reference_bff_client_block="$(
  sed -n \
    '/^[[:space:]]*module[[:space:]]*"identity_cognito_reference_bff_client"[[:space:]]*{[[:space:]]*$/,/^[[:space:]]*}[[:space:]]*$/p' \
    "$core_main"
)"
require_text_count 8 '^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*=' \
  "$identity_reference_bff_client_block" "production reference BFF client module must contain exactly count, source, five approved inputs, and the federation dependency"
require_text_count 1 '^[[:space:]]*count[[:space:]]*=[[:space:]]*var[.]enable_identity_reference_bff_client[[:space:]]*[?][[:space:]]*1[[:space:]]*:[[:space:]]*0[[:space:]]*$' \
  "$identity_reference_bff_client_block" "production reference BFF client module must use only its explicit boolean gate"
require_text_count 1 '^[[:space:]]*source[[:space:]]*=[[:space:]]*"[.][.]/[.][.]/[.][.]/modules/identity_cognito_reference_bff_client"[[:space:]]*$' \
  "$identity_reference_bff_client_block" "production reference BFF client module source must remain exact"
require_text_count 1 '^[[:space:]]*user_pool_id[[:space:]]*=[[:space:]]*one[(]module[.]identity_cognito_core\[\*\][.]user_pool_id[)][[:space:]]*$' \
  "$identity_reference_bff_client_block" "production reference BFF client must fail closed on a missing Cognito core User Pool"
require_text_count 1 '^[[:space:]]*profile_read_scope_identifier[[:space:]]*=[[:space:]]*one[(]module[.]identity_cognito_core\[\*\][.]profile_read_scope_identifier[)][[:space:]]*$' \
  "$identity_reference_bff_client_block" "production reference BFF client must consume the exact Cognito core profile-read scope"
require_text_count 1 '^[[:space:]]*profile_write_scope_identifier[[:space:]]*=[[:space:]]*one[(]module[.]identity_cognito_core\[\*\][.]profile_write_scope_identifier[)][[:space:]]*$' \
  "$identity_reference_bff_client_block" "production reference BFF client must consume the exact Cognito core profile-write scope"
require_text_count 1 '^[[:space:]]*name_prefix[[:space:]]*=[[:space:]]*local[.]name_prefix[[:space:]]*$' \
  "$identity_reference_bff_client_block" "production reference BFF client must use the canonical name prefix"
require_text_count 1 '^[[:space:]]*application_origins[[:space:]]*=[[:space:]]*var[.]identity_reference_bff_application_origins[[:space:]]*$' \
  "$identity_reference_bff_client_block" "production reference BFF client must consume only the validated root origins"
require_text_count 1 '^[[:space:]]*depends_on[[:space:]]*=[[:space:]]*\[module[.]identity_authentication\][[:space:]]*$' \
  "$identity_reference_bff_client_block" "production reference BFF client must wait for the sole Google federation module"

for gate in enable_identity_cognito_core enable_identity_auth_certificate enable_identity_auth_certificate_validation enable_identity_google_federation enable_identity_auth_domain enable_identity_reference_bff_client enable_identity_client_secret_custody; do
  require_count 1 "^[[:space:]]*$gate[[:space:]]*=[[:space:]]*false[[:space:]]*$" \
    "$core_values" "every committed Identity authentication gate must remain explicitly false"
done
require_count 1 '^[[:space:]]*identity_reference_bff_application_origins[[:space:]]*=[[:space:]]*\[\][[:space:]]*$' \
  "$core_values" "the committed reference BFF application origin collection must remain empty"
require_count 1 '^[[:space:]]*identity_google_credentials_secret_arn[[:space:]]*=[[:space:]]*null[[:space:]]*$' \
  "$core_values" "the committed Google credential reference must remain null"
reject_pattern 'https://' "$core_main" \
  "production core module wiring must not contain a committed application origin"

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

client_root_output_names=(
  identity_reference_bff_callback_urls
  identity_reference_bff_client_id
  identity_reference_bff_logout_urls
)
for output_name in "${client_root_output_names[@]}"; do
  require_count 1 "^output[[:space:]]+\"$output_name\"[[:space:]]*\\{" \
    "$core_outputs" "production reference BFF root output is missing or duplicated: $output_name"
done
require_count 3 '^[[:space:]]*value[[:space:]]*=[[:space:]]*var[.]enable_identity_reference_bff_client[[:space:]]*[?].*:[[:space:]]*null[[:space:]]*$' \
  "$core_outputs" "all reference BFF root outputs must be null when the feature gate is disabled"
reject_pattern '(client_secret|sensitive[[:space:]]*=[[:space:]]*true)' "$core_outputs" \
  "production core must never expose the reference BFF client secret"
reject_pattern 'https://' "$core_outputs" \
  "production core outputs must not contain a committed application origin"

reject_aggregate_pattern '^[[:space:]]*resource[[:space:]]+"(aws_iam_access_key|aws_lambda_[^" ]*)"' \
  "static credentials and Lambda resources remain forbidden" "${tofu_files[@]}"

require_count 1 "$google_provider_block_pattern" "$authentication_module_main" \
  "the authentication module must contain exactly one Google identity provider"
require_count 1 "$domain_block_pattern" "$authentication_module_main" \
  "the authentication module must contain exactly one custom Cognito domain"
require_count 1 '^[[:space:]]*provider_name[[:space:]]*=[[:space:]]*"Google"[[:space:]]*$' \
  "$authentication_module_main" "the sole Cognito identity provider must be Google"
require_count 1 '^[[:space:]]*provider_type[[:space:]]*=[[:space:]]*"Google"[[:space:]]*$' \
  "$authentication_module_main" "the sole Cognito identity-provider type must be Google"
reject_pattern '"(COGNITO|Facebook|LoginWithAmazon|SignInWithApple|SAML|OIDC)"' "$authentication_module_main" \
  "no additional or native Cognito identity provider may be enabled"

if ((failures > 0)); then
  printf 'Cognito core policy checks failed with %d violation(s).\n' "$failures" >&2
  exit 1
fi

printf 'Cognito core policy checks passed.\n'
