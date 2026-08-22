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
  "infra/live/production/runtime/providers.tf"
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

instance_public_ip_assignment_pattern='^[[:space:]]*associate_public_ip_address[[:space:]]*='
mapfile -t matches < <(grep -El "$instance_public_ip_assignment_pattern" "${tofu_files[@]}" || true)
if ((${#matches[@]} > 0)); then
  report_files "instance-level public-IP assignment must remain unset" "${matches[@]}"
fi

network_module_file="infra/modules/network/main.tf"
subnet_public_ip_assignment_pattern='^[[:space:]]*map_public_ip_on_launch[[:space:]]*='
subnet_public_ip_disabled_pattern='^[[:space:]]*map_public_ip_on_launch[[:space:]]*=[[:space:]]*false[[:space:]]*$'
if [[ ! -f "$network_module_file" ]]; then
  report_files "required network module file is missing" "$network_module_file"
else
  subnet_assignment_count="$(grep -Ec "$subnet_public_ip_assignment_pattern" "$network_module_file" || true)"
  subnet_disabled_count="$(grep -Ec "$subnet_public_ip_disabled_pattern" "$network_module_file" || true)"
  if [[ "$subnet_assignment_count" != "1" || "$subnet_disabled_count" != "1" ]]; then
    report_files "network module must disable automatic public-IP assignment exactly once" "$network_module_file"
  fi
fi

host_module_file="infra/modules/host/main.tf"
eip_resource_pattern='^[[:space:]]*resource[[:space:]]+"aws_eip"[[:space:]]+"this"[[:space:]]*\{[[:space:]]*$'
eip_association_resource_pattern='^[[:space:]]*resource[[:space:]]+"aws_eip_association"[[:space:]]+"this"[[:space:]]*\{[[:space:]]*$'
eip_allocation_link_pattern='^[[:space:]]*allocation_id[[:space:]]*=[[:space:]]*aws_eip[.]this[.]id[[:space:]]*$'
eip_instance_link_pattern='^[[:space:]]*instance_id[[:space:]]*=[[:space:]]*aws_instance[.]this[.]id[[:space:]]*$'

if [[ ! -f "$host_module_file" ]]; then
  report_files "required host module file is missing" "$host_module_file"
else
  if [[ "$(grep -Ec "$eip_resource_pattern" "$host_module_file" || true)" != "1" ]]; then
    report_files "host module must manage exactly one Elastic IP resource" "$host_module_file"
  fi
  if [[ "$(grep -Ec "$eip_association_resource_pattern" "$host_module_file" || true)" != "1" ]]; then
    report_files "host module must manage exactly one Elastic IP association" "$host_module_file"
  fi
  if [[ "$(grep -Ec "$eip_allocation_link_pattern" "$host_module_file" || true)" != "1" ]]; then
    report_files "Elastic IP association must reference the managed allocation" "$host_module_file"
  fi
  if [[ "$(grep -Ec "$eip_instance_link_pattern" "$host_module_file" || true)" != "1" ]]; then
    report_files "Elastic IP association must reference the managed instance" "$host_module_file"
  fi
fi

lifecycle_public_ip_ignore_files=()
for file in "${tofu_files[@]}"; do
  if awk '
    BEGIN { in_ignore_list = 0; found = 0 }
    {
      line = $0
      sub(/[[:space:]]*#.*/, "", line)
      sub(/[[:space:]]*\/\/.*/, "", line)

      if (line ~ /^[[:space:]]*ignore_changes[[:space:]]*=/) {
        if (line ~ /associate_public_ip_address/) {
          found = 1
        }
        in_ignore_list = (line ~ /\[/ && line !~ /\]/)
        next
      }

      if (in_ignore_list) {
        if (line ~ /associate_public_ip_address/) {
          found = 1
        }
        if (line ~ /\]/) {
          in_ignore_list = 0
        }
      }
    }
    END { exit found ? 0 : 1 }
  ' "$file"; then
    lifecycle_public_ip_ignore_files+=("$file")
  fi
done
if ((${#lifecycle_public_ip_ignore_files[@]} > 0)); then
  report_files "lifecycle ignore rule targets the computed public-IP association attribute" \
    "${lifecycle_public_ip_ignore_files[@]}"
fi

active_backend_files=(
  "infra/bootstrap/state/backend.tf"
  "infra/bootstrap/account/backend.tf"
  "infra/live/production/core/backend.tf"
  "infra/live/production/runtime/backend.tf"
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
  "infra/live/production/runtime/backend.hcl.example"
)
backend_example_keys=(
  "bootstrap/state/tofu.tfstate"
  "bootstrap/account/tofu.tfstate"
  "production/core/tofu.tfstate"
  "production/runtime/tofu.tfstate"
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

runtime_root="infra/live/production/runtime"
runtime_required_files=(
  "$runtime_root/backend.tf"
  "$runtime_root/backend.hcl.example"
  "$runtime_root/main.tf"
  "$runtime_root/providers.tf"
  "$runtime_root/variables.tf"
  "$runtime_root/versions.tf"
  "$runtime_root/.terraform.lock.hcl"
)
for file in "${runtime_required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    report_files "required production runtime root file is missing" "$file"
  fi
done

if [[ -f "$runtime_root/main.tf" ]]; then
  if [[ "$(grep -Fxc '    key                 = "production/core/tofu.tfstate"' "$runtime_root/main.tf" || true)" != "1" ]]; then
    report_files "runtime root must read the exact production-core state key" "$runtime_root/main.tf"
  fi

  approved_core_outputs=(
    artifact_bucket_arn
    artifact_bucket_name
    backup_bucket_arn
    backup_bucket_name
    domains
    elastic_ip
    instance_arn
    instance_id
    instance_profile_name
    instance_role_arn
    root_volume_id
  )
  mapfile -t referenced_core_outputs < <(
    grep -Eo 'data[.]terraform_remote_state[.]core[.]outputs[.][A-Za-z0-9_]+' "$runtime_root/main.tf" \
      | awk -F. '{print $NF}' \
      | sort -u
  )
  mapfile -t unexpected_core_outputs < <(
    comm -23 \
      <(printf '%s\n' "${referenced_core_outputs[@]}" | sort -u) \
      <(printf '%s\n' "${approved_core_outputs[@]}" | sort -u)
  )
  if ((${#unexpected_core_outputs[@]} > 0)); then
    report_files "runtime root consumes an unapproved production-core output" "$runtime_root/main.tf"
  fi
fi

oidc_file="infra/modules/deployment/github_oidc.tf"
if [[ ! -f "$oidc_file" ]]; then
  report_files "GitHub OIDC source is missing" "$oidc_file"
else
  if ! grep -Eq '^[[:space:]]*url[[:space:]]*=[[:space:]]*"https://token[.]actions[.]githubusercontent[.]com"[[:space:]]*$' "$oidc_file"; then
    report_files "GitHub OIDC provider URL is not exact" "$oidc_file"
  fi
  if ! grep -Fq 'client_id_list' "$oidc_file" || ! grep -Fq '"sts.amazonaws.com"' "$oidc_file"; then
    report_files "GitHub OIDC audience is not exact" "$oidc_file"
  fi
  if grep -Eq '^[[:space:]]*thumbprint_list[[:space:]]*=' "$oidc_file"; then
    report_files "GitHub OIDC provider must not configure a thumbprint" "$oidc_file"
  fi
  if ! grep -Fq 'github_subject = "repo:${var.github_owner}@${format("%.0f", var.github_owner_id)}/${var.github_repository}@${format("%.0f", var.github_repository_id)}:environment:${var.github_environment}"' "$oidc_file"; then
    report_files "GitHub OIDC subject must bind immutable owner/repository IDs and the environment" "$oidc_file"
  fi
  if grep -E 'github_subject.*[*]|token[.]actions[.]githubusercontent[.]com:sub.*[*]' "$oidc_file" >/dev/null; then
    report_files "wildcard GitHub OIDC subject" "$oidc_file"
  fi
fi

deployment_iam_file="infra/modules/deployment/iam.tf"
if [[ ! -f "$deployment_iam_file" ]]; then
  report_files "deployment IAM policy source is missing" "$deployment_iam_file"
else
  if grep -Eq 's3:(Delete|PutBucket|PutLifecycle|PutBucketPolicy|PutBucketAcl)' "$deployment_iam_file"; then
    report_files "deployment role contains an S3 delete or bucket-mutation permission" "$deployment_iam_file"
  fi
  if grep -Fq 'AWS-RunShellScript' "$deployment_iam_file"; then
    report_files "GitHub deployment role may invoke the arbitrary AWS shell document" "$deployment_iam_file"
  fi
fi

workflow_file=".github/workflows/deploy-portfolio.yml"
if [[ ! -f "$workflow_file" ]]; then
  report_files "immutable deployment workflow is missing" "$workflow_file"
else
  if ! grep -Eq '^[[:space:]]+environment:[[:space:]]+production[[:space:]]*$' "$workflow_file"; then
    report_files "deployment workflow must use the protected production environment" "$workflow_file"
  fi
  for permission in 'contents: read' 'id-token: write' 'attestations: write'; do
    if [[ "$(grep -Fxc "  $permission" "$workflow_file" || true)" != "1" ]]; then
      report_files "deployment workflow permission set is incomplete or duplicated" "$workflow_file"
    fi
  done
  mapfile -t unpinned_actions < <(
    awk '
      /^[[:space:]]*uses:[[:space:]]*/ {
        value = $0
        sub(/^[[:space:]]*uses:[[:space:]]*/, "", value)
        if (value !~ /^(actions|aws-actions)\/[A-Za-z0-9._-]+@[0-9a-f]{40}$/) print FILENAME
      }
    ' "$workflow_file" | sort -u
  )
  if ((${#unpinned_actions[@]} > 0)); then
    report_files "workflow action is not official and pinned to a full commit SHA" "${unpinned_actions[@]}"
  fi
  if grep -Eq 'aws-access-key-id|aws-secret-access-key|AWS-RunShellScript|pull_request_target' "$workflow_file"; then
    report_files "deployment workflow contains a stored-key, arbitrary-shell, or untrusted-trigger pattern" "$workflow_file"
  fi
fi

nginx_files=(
  "config/nginx/nginx.conf"
  "config/nginx/portfolio-http.conf.tftpl"
  "config/nginx/portfolio-tls.conf.tftpl"
  "config/nginx/security-headers.conf"
)
for file in "${nginx_files[@]}"; do
  [[ -f "$file" ]] || report_files "required Nginx contract file is missing" "$file"
done
if [[ -f config/nginx/nginx.conf ]]; then
  for token in '$uri' '$request_method' '$server_protocol' '$status' '$body_bytes_sent' '$request_time' '$realpath_root'; do
    grep -Fq "$token" config/nginx/nginx.conf || report_files "Nginx safe access log is missing a required field" config/nginx/nginx.conf
  done
  if grep -Eq '\$args|\$cookie_|\$http_authorization|\$request_body|"\$request"' config/nginx/nginx.conf; then
    report_files "Nginx log format contains query, cookie, authorization, body, or raw-request data" config/nginx/nginx.conf
  fi
fi
for file in config/nginx/portfolio-http.conf.tftpl config/nginx/portfolio-tls.conf.tftpl; do
  if [[ -f "$file" ]]; then
    for token in 'text/x-script' 'application/rss+xml; charset=utf-8' 'application/xml; charset=utf-8' 'no-cache, max-age=0, must-revalidate' 'public, max-age=31536000, immutable' 'no-store' '__spa-fallback.html' '=404'; do
      grep -Fq "$token" "$file" || report_files "Nginx routing, MIME, cache, or 404 contract is incomplete" "$file"
    done
  fi
done

release_manifest="deploy/releases/website-v1.0.0.json"
if [[ ! -f "$release_manifest" ]] || ! jq -e '
  .release.sourceRepository == "https://github.com/rahulyadev/website" and
  .release.tag == "v1.0.0" and
  .release.commit == "0bfde1c170e2b27ec92d98504b6fa25d66543bed" and
  .expectedArtifact.sha256 == "bd43b937c621752a94c67c7a1b6495fa837d7ffd43b2bb1a5534a7442a54673d" and
  .expectedArtifact.manifestSha256 == "cc73b3874f514f19557a2f235eb4123199d366cc7c7ed7442b84daa0bc3a0138" and
  .toolchain.node == "24.19.0" and
  .toolchain.npm == "11.17.0" and
  .commands.install == "npm ci" and
  .commands.verify == "npm run verify" and
  .commands.e2e == "npm run test:e2e" and
  .commands.build == "npm run build" and
  .outputDirectory == "build/client" and
  .runtimeEnvironmentVariables == []
' "$release_manifest" >/dev/null 2>&1; then
  report_files "immutable website release manifest does not match the approved release" "$release_manifest"
fi

snapshot_file="infra/modules/snapshot_policy/main.tf"
if [[ ! -f "$snapshot_file" ]]; then
  report_files "snapshot-policy source is missing" "$snapshot_file"
else
  if [[ "$(grep -Ec '^[[:space:]]*resource[[:space:]]+"aws_dlm_lifecycle_policy"[[:space:]]+"production"[[:space:]]*\{[[:space:]]*$' "$snapshot_file" || true)" != "1" ]] || \
    [[ "$(grep -Fxc '    resource_types = ["INSTANCE"]' "$snapshot_file" || true)" != "1" ]]; then
    report_files "snapshot policy must remain an instance-targeted DLM lifecycle policy" "$snapshot_file"
  fi
  if [[ "$(grep -Ec '^[[:space:]]*exclude_boot_volume[[:space:]]*=[[:space:]]*false[[:space:]]*$' "$snapshot_file" || true)" != "1" ]]; then
    report_files "snapshot policy must include the boot volume exactly once" "$snapshot_file"
  fi
  if grep -Eq '^[[:space:]]*no_reboot[[:space:]]*=' "$snapshot_file"; then
    report_files "EBS snapshot-management policy must not configure the AMI-only no_reboot parameter" "$snapshot_file"
  fi
  if [[ "$(grep -Ec 'cron_expression[[:space:]]*=[[:space:]]*"cron\(0 (3 \* \*|4 1 \*) \? \*\)"' "$snapshot_file" || true)" != "2" ]]; then
    report_files "daily and monthly instance snapshot schedules are incomplete" "$snapshot_file"
  fi
fi

monitoring_alarm_file="infra/modules/monitoring/alarms.tf"
if [[ -f "$monitoring_alarm_file" ]]; then
  for metric in StatusCheckFailed CPUUtilization CPUCreditBalance CPUSurplusCreditsCharged mem_used_percent disk_used_percent disk_inodes_used disk_inodes_total procstat_lookup_pid_count; do
    grep -Fq "\"$metric\"" "$monitoring_alarm_file" || report_files "required runtime alarm metric is missing" "$monitoring_alarm_file"
  done
  grep -Fq 'expression  = "100 * inode_used / inode_total"' "$monitoring_alarm_file" || \
    report_files "root inode alarm does not calculate a percentage from emitted inode metrics" "$monitoring_alarm_file"
  if grep -Fq 'disk_inodes_used_percent' "$monitoring_alarm_file"; then
    report_files "root inode alarm references a metric the CloudWatch Agent does not emit" "$monitoring_alarm_file"
  fi
else
  report_files "runtime alarm source is missing" "$monitoring_alarm_file"
fi

cloudwatch_agent_file="config/cloudwatch/agent-config.json.tftpl"
if [[ -f "$cloudwatch_agent_file" ]]; then
  for metric in used_percent inodes_used inodes_total; do
    grep -Fq "\"$metric\"" "$cloudwatch_agent_file" || report_files "CloudWatch Agent disk measurement is missing" "$cloudwatch_agent_file"
  done
  if grep -Fq 'inodes_used_percent' "$cloudwatch_agent_file"; then
    report_files "CloudWatch Agent configuration contains an unsupported inode percentage measurement" "$cloudwatch_agent_file"
  fi
  if ! jq -e '
    .metrics.metrics_collected.mem.measurement == ["used_percent"] and
    (.metrics.metrics_collected.mem | has("drop_original_metrics") | not) and
    .metrics.metrics_collected.swap.measurement == ["used_percent"] and
    (.metrics.metrics_collected.swap | has("drop_original_metrics") | not) and
    .metrics.metrics_collected.disk.drop_original_metrics == ["used_percent", "inodes_used", "inodes_total"] and
    ([
      .metrics.metrics_collected
      | to_entries[]
      | select(.value | type == "object")
      | select(.value | has("drop_original_metrics"))
      | .key
    ] == ["disk"])
  ' "$cloudwatch_agent_file" >/dev/null; then
    report_files "CloudWatch Agent memory, swap, or disk metric aggregation is unsafe" "$cloudwatch_agent_file"
  fi
else
  report_files "CloudWatch Agent configuration template is missing" "$cloudwatch_agent_file"
fi

if ((failures > 0)); then
  printf 'Policy checks failed with %d category violation(s).\n' "$failures" >&2
  exit 1
fi

printf 'Policy checks passed.\n'
