#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd -- "$repository_root"

failures=0

report_files() {
  local message="$1"
  shift
  printf 'POLICY FAILURE: %s\n' "$message" >&2
  printf '  %s\n' "$@" >&2
  failures=$((failures + 1))
}

mapfile -t candidate_files < <(
  while IFS= read -r file; do
    [[ -f "$file" ]] && printf '%s\n' "$file"
  done < <(git ls-files --cached --others --exclude-standard)
)
mapfile -t tofu_files < <(
  git ls-files --cached --others --exclude-standard -- '*.tf'
)
mapfile -t tracked_files < <(
  git ls-files --cached
)

if ((${#tofu_files[@]} == 0)); then
  printf 'POLICY FAILURE: no active OpenTofu files were found.\n' >&2
  exit 1
fi

provider_files=(
  "infra/bootstrap/state/providers.tf"
  "infra/bootstrap/account/providers.tf"
  "infra/live/production/core/providers.tf"
)
provider_allowlist_pattern='^[[:space:]]*allowed_account_ids[[:space:]]*=[[:space:]]*\[var[.]expected_account_id\][[:space:]]*$'

for file in "${provider_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    report_files "required root provider file is missing" "$file"
    continue
  fi

  match_count="$(grep -Ec "$provider_allowlist_pattern" "$file" || true)"
  if [[ "$match_count" != "1" ]]; then
    report_files "root provider must contain exactly one expected-account allowlist" "$file"
  fi
done

mapfile -t matches < <(grep -El '^[[:space:]]*check[[:space:]]+"expected_account"' "${tofu_files[@]}" || true)
if ((${#matches[@]} > 0)); then
  report_files "warning-only expected-account check in active OpenTofu" "${matches[@]}"
fi

active_backend_files=(
  "infra/bootstrap/state/backend.tf"
  "infra/bootstrap/account/backend.tf"
  "infra/live/production/core/backend.tf"
)
backend_declaration_pattern='^[[:space:]]*backend[[:space:]]+"[^"]+"[[:space:]]*\{[[:space:]]*$'
s3_backend_pattern='^[[:space:]]*backend[[:space:]]+"s3"[[:space:]]*\{[[:space:]]*$'
backend_encrypt_pattern='^[[:space:]]*encrypt[[:space:]]*=[[:space:]]*true[[:space:]]*$'
backend_lockfile_pattern='^[[:space:]]*use_lockfile[[:space:]]*=[[:space:]]*true[[:space:]]*$'

for file in "${active_backend_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    report_files "required active backend file is missing" "$file"
    continue
  fi

  declaration_count="$(grep -Ec "$backend_declaration_pattern" "$file" || true)"
  s3_count="$(grep -Ec "$s3_backend_pattern" "$file" || true)"
  encrypt_count="$(grep -Ec "$backend_encrypt_pattern" "$file" || true)"
  lockfile_count="$(grep -Ec "$backend_lockfile_pattern" "$file" || true)"

  if [[ "$declaration_count" != "1" || "$s3_count" != "1" ]]; then
    report_files "root must contain exactly one active S3 backend" "$file"
  fi
  if [[ "$encrypt_count" != "1" ]]; then
    report_files "active S3 backend must enable encryption exactly once" "$file"
  fi
  if [[ "$lockfile_count" != "1" ]]; then
    report_files "active S3 backend must enable native lock files exactly once" "$file"
  fi
done

mapfile -t matches < <(grep -El '^[[:space:]]*backend[[:space:]]+"local"' "${tofu_files[@]}" || true)
if ((${#matches[@]} > 0)); then
  report_files "active local backend declaration" "${matches[@]}"
fi

obsolete_backend_files=(
  "infra/bootstrap/state/backend.s3.tf.example"
  "infra/bootstrap/account/backend.s3.tf.example"
)
for file in "${obsolete_backend_files[@]}"; do
  if [[ -e "$file" ]]; then
    report_files "obsolete bootstrap S3 backend example still exists" "$file"
  fi
done

backend_example_files=(
  "infra/bootstrap/state/backend.hcl.example"
  "infra/bootstrap/account/backend.hcl.example"
  "infra/live/production/core/backend.hcl.example"
)
backend_example_keys=(
  "bootstrap/state/tofu.tfstate"
  "bootstrap/account/tofu.tfstate"
  "production/core/tofu.tfstate"
)
backend_allowlist_pattern='^[[:space:]]*allowed_account_ids[[:space:]]*=[[:space:]]*\["000000000000"\][[:space:]]*$'
backend_example_encrypt_pattern='^[[:space:]]*encrypt[[:space:]]*=[[:space:]]*true[[:space:]]*$'
backend_example_lockfile_pattern='^[[:space:]]*use_lockfile[[:space:]]*=[[:space:]]*true[[:space:]]*$'

for index in "${!backend_example_files[@]}"; do
  file="${backend_example_files[$index]}"
  expected_key="${backend_example_keys[$index]}"

  if [[ ! -f "$file" ]]; then
    report_files "required backend configuration example is missing" "$file"
    continue
  fi

  match_count="$(grep -Ec "$backend_allowlist_pattern" "$file" || true)"
  if [[ "$match_count" != "1" ]]; then
    report_files "backend example must contain exactly one account allowlist placeholder" "$file"
  fi

  key_count="$(grep -Fxc "key    = \"$expected_key\"" "$file" || true)"
  if [[ "$key_count" != "1" ]]; then
    report_files "backend example has an incorrect or missing state key" "$file"
  fi

  encrypt_count="$(grep -Ec "$backend_example_encrypt_pattern" "$file" || true)"
  if [[ "$encrypt_count" != "1" ]]; then
    report_files "backend example must enable encryption exactly once" "$file"
  fi

  lockfile_count="$(grep -Ec "$backend_example_lockfile_pattern" "$file" || true)"
  if [[ "$lockfile_count" != "1" ]]; then
    report_files "backend example must enable native lock files exactly once" "$file"
  fi
done

obsolete_backend_reference_pattern='backend[.]s3[.]tf[.]example'
backend_reference_files=()
for file in "${candidate_files[@]}"; do
  [[ "$file" == "scripts/check-policy.sh" ]] || backend_reference_files+=("$file")
done
mapfile -t matches < <(grep -El "$obsolete_backend_reference_pattern" "${backend_reference_files[@]}" || true)
if ((${#matches[@]} > 0)); then
  report_files "source or documentation references a deleted backend example" "${matches[@]}"
fi

ambiguous_backend_guidance=()
for file in "${candidate_files[@]}"; do
  if grep -Ei '(add|append|copy)[[:space:]].*(second|another)[[:space:]].*backend' "$file" \
    | grep -Eiv '(do not|never|must not|without)' >/dev/null; then
    ambiguous_backend_guidance+=("$file")
  fi
done
if ((${#ambiguous_backend_guidance[@]} > 0)); then
  report_files "documentation suggests adding another active backend block" \
    "${ambiguous_backend_guidance[@]}"
fi

validation_script="scripts/validate.sh"
if ! grep -Eq 'validation_root="\$\(mktemp -d\)"' "$validation_script"; then
  report_files "validation must create one external temporary data root" "$validation_script"
fi
if ! grep -Eq '^[[:space:]]*chmod 0700 "\$validation_root"[[:space:]]*$' "$validation_script"; then
  report_files "validation temporary root must use mode 0700" "$validation_script"
fi
if ! grep -Fq 'data_dir="$validation_root/${root//\//-}"' "$validation_script"; then
  report_files "validation must assign a distinct external TF_DATA_DIR per root" "$validation_script"
fi
if [[ "$(grep -Ec '^[[:space:]]*TF_DATA_DIR="\$data_dir"[[:space:]]+tofu init' "$validation_script" || true)" != "1" ]]; then
  report_files "validation init must use the root-specific external TF_DATA_DIR" "$validation_script"
fi
if [[ "$(grep -Ec '^[[:space:]]*TF_DATA_DIR="\$data_dir"[[:space:]]+tofu validate' "$validation_script" || true)" != "1" ]]; then
  report_files "validation must use the same root-specific external TF_DATA_DIR" "$validation_script"
fi
if grep -Eq '^[[:space:]]*tofu[[:space:]]+(init|validate)' "$validation_script"; then
  report_files "validation command can use an authoritative root .terraform directory" "$validation_script"
fi
if ! grep -Eq '^[[:space:]]*trap cleanup_validation_root EXIT[[:space:]]*$' "$validation_script"; then
  report_files "validation temporary root must be removed through an EXIT trap" "$validation_script"
fi

tracked_runtime_variable_files=()
for file in "${tracked_files[@]}"; do
  case "${file##*/}" in
    terraform.tfvars | terraform.tfvars.json)
      tracked_runtime_variable_files+=("$file")
      ;;
  esac
done
if ((${#tracked_runtime_variable_files[@]} > 0)); then
  report_files "tracked runtime Terraform variable file" "${tracked_runtime_variable_files[@]}"
fi

forbidden_resources='aws_nat_gateway|aws_lb|aws_alb|aws_db_instance|aws_rds_cluster|aws_ecs_|aws_eks_|kubernetes_|aws_elasticache_|aws_mq_|aws_route53_zone|aws_route53_record|aws_acm_certificate|aws_cognito_'
mapfile -t matches < <(grep -El "$forbidden_resources" "${tofu_files[@]}" || true)
if ((${#matches[@]} > 0)); then
  report_files "forbidden service token in active OpenTofu" "${matches[@]}"
fi

mapfile -t matches < <(grep -El '(^|[[:space:]])(from_port|to_port)[[:space:]]*=[[:space:]]*22([[:space:]]|$)' "${tofu_files[@]}" || true)
if ((${#matches[@]} > 0)); then
  report_files "TCP port 22 rule in active OpenTofu" "${matches[@]}"
fi

mapfile -t matches < <(grep -El '^[[:space:]]*key_name[[:space:]]*=' "${tofu_files[@]}" || true)
if ((${#matches[@]} > 0)); then
  report_files "EC2 key_name configuration" "${matches[@]}"
fi

mapfile -t matches < <(grep -El '^[[:space:]]*encrypted[[:space:]]*=[[:space:]]*false' "${tofu_files[@]}" || true)
if ((${#matches[@]} > 0)); then
  report_files "explicitly unencrypted storage configuration" "${matches[@]}"
fi

if grep -Eq 'resource[[:space:]]+"aws_instance"' infra/modules/host/main.tf; then
  if ! grep -Eq '^[[:space:]]*encrypted[[:space:]]*=[[:space:]]*true' infra/modules/host/main.tf; then
    report_files "host root volume does not assert encryption" infra/modules/host/main.tf
  fi
  if ! grep -Eq '^[[:space:]]*http_tokens[[:space:]]*=[[:space:]]*"required"' infra/modules/host/main.tf; then
    report_files "host does not require IMDSv2 tokens" infra/modules/host/main.tf
  fi
fi

mapfile -t matches < <(grep -El '^[[:space:]]*http_tokens[[:space:]]*=[[:space:]]*"(optional|disabled)"' "${tofu_files[@]}" || true)
if ((${#matches[@]} > 0)); then
  report_files "IMDS token configuration is not required" "${matches[@]}"
fi

mapfile -t matches < <(grep -El 'dynamodb_table' "${tofu_files[@]}" || true)
if ((${#matches[@]} > 0)); then
  report_files "DynamoDB state-lock configuration" "${matches[@]}"
fi

public_s3_pattern='aws_s3_bucket_acl|aws_s3_bucket_website|website[[:space:]]*\{|acl[[:space:]]*=[[:space:]]*"public'
mapfile -t matches < <(grep -El "$public_s3_pattern" "${tofu_files[@]}" || true)
if ((${#matches[@]} > 0)); then
  report_files "public S3 ACL or website-hosting configuration" "${matches[@]}"
fi

domain_pattern='rahuly[.]in'
mapfile -t matches < <(grep -El "$domain_pattern" "${tofu_files[@]}" || true)
if ((${#matches[@]} > 0)); then
  report_files "environment domain hardcoded in active OpenTofu" "${matches[@]}"
fi

real_account_id_files=()
for file in "${candidate_files[@]}"; do
  if awk '
    {
      if ($0 ~ /^[[:space:]]*"(h1|zh):[A-Za-z0-9+\/=]+",?[[:space:]]*$/) {
        next
      }
      line = $0
      gsub(/000000000000/, "", line)
      if (line ~ /(^|[^0-9])[0-9]{12}([^0-9]|$)/) {
        found = 1
      }
    }
    END { exit found ? 0 : 1 }
  ' "$file"; then
    real_account_id_files+=("$file")
  fi
done
if ((${#real_account_id_files[@]} > 0)); then
  report_files "non-placeholder twelve-digit account ID in repository content" "${real_account_id_files[@]}"
fi

email_pattern='[A-Za-z0-9.!#$%&*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}'
allowed_email='budget-notifications@example.com'
real_email_files=()
for file in "${candidate_files[@]}"; do
  if grep -Eo "$email_pattern" "$file" | grep -Fvx "$allowed_email" >/dev/null; then
    real_email_files+=("$file")
  fi
done
if ((${#real_email_files[@]} > 0)); then
  report_files "non-placeholder email address in repository content" "${real_email_files[@]}"
fi

credential_pattern='A[K]IA|A[S]IA'
mapfile -t matches < <(grep -El "$credential_pattern" "${candidate_files[@]}" || true)
if ((${#matches[@]} > 0)); then
  report_files "string matching a common AWS access-key prefix" "${matches[@]}"
fi

credential_assignment_pattern='(aws_''access_''key_''id|access_''key_''id|aws_''secret_''access_''key|secret_''access_''key|aws_''session_''token|session_''token)[[:space:]]*[:=]'
mapfile -t matches < <(grep -Eil "$credential_assignment_pattern" "${candidate_files[@]}" || true)
if ((${#matches[@]} > 0)); then
  report_files "credential-like assignment in repository content" "${matches[@]}"
fi

private_key_header_pattern='-----BEGIN ''([A-Z0-9 ]+ )?PRIVATE ''KEY-----'
mapfile -t matches < <(grep -El -- "$private_key_header_pattern" "${candidate_files[@]}" || true)
if ((${#matches[@]} > 0)); then
  report_files "private-key header in repository content" "${matches[@]}"
fi

unsafe_file_pattern='(^|/)(backend[.]hcl|[.]env([.]|$)|secrets)(/|$)|[.]tfstate([.]|$)|[.]tfplan$|[.]plan$|[.](pem|key|p12|pfx)$'
unsafe_files=()
for file in "${candidate_files[@]}"; do
  if [[ "$file" =~ $unsafe_file_pattern ]]; then
    unsafe_files+=("$file")
  fi
done
if ((${#unsafe_files[@]} > 0)); then
  report_files "unsafe state, plan, environment, key, secret, or backend file" "${unsafe_files[@]}"
fi

if ((failures > 0)); then
  printf 'Policy checks failed with %d category violation(s).\n' "$failures" >&2
  exit 1
fi

printf 'Policy checks passed.\n'
