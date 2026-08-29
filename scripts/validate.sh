#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd -- "$repository_root"

required_tofu_version="1.12.5"
installed_tofu_version="$(tofu version | awk 'NR == 1 { sub(/^OpenTofu v/, ""); print }')"

if [[ "$installed_tofu_version" != "$required_tofu_version" ]]; then
  printf 'OpenTofu %s is required; found %s.\n' \
    "$required_tofu_version" "$installed_tofu_version" >&2
  exit 1
fi

printf 'Checking OpenTofu formatting...\n'
tofu fmt -check -recursive

roots=(
  "infra/bootstrap/state"
  "infra/bootstrap/account"
  "infra/live/production/core"
  "infra/live/production/runtime"
)

validation_root="$(mktemp -d)"
chmod 0700 "$validation_root"

cleanup_validation_root() {
  rm -rf -- "$validation_root"
}
trap cleanup_validation_root EXIT

case "$validation_root/" in
  "$repository_root/"*)
    printf 'Temporary validation data must be outside the repository.\n' >&2
    exit 1
    ;;
esac

for root in "${roots[@]}"; do
  data_dir="$validation_root/${root//\//-}"
  mkdir -m 0700 -- "$data_dir"

  printf 'Initializing %s with its backend disabled...\n' "$root"
  (
    cd -- "$root"
    TF_DATA_DIR="$data_dir" tofu init \
      -backend=false \
      -input=false \
      -lockfile=readonly \
      -no-color
  )

  printf 'Validating %s...\n' "$root"
  (
    cd -- "$root"
    TF_DATA_DIR="$data_dir" tofu validate -no-color
  )
done

printf 'Checking shell syntax...\n'
mapfile -t shell_scripts < <(
  git ls-files --cached --others --exclude-standard -- '*.sh'
)

if ((${#shell_scripts[@]} == 0)); then
  printf 'No repository shell scripts were found.\n' >&2
  exit 1
fi

bash -n "${shell_scripts[@]}"
bash -n infra/modules/host/user_data.sh.tftpl

printf 'Checking rendered shell-template syntax...\n'
for template in deploy/ssm/configure-runtime.sh.tftpl deploy/ssm/enable-tls.sh.tftpl \
  deploy/ssm/configure-identity-runtime.sh.tftpl; do
  rendered="$validation_root/$(basename "$template" .tftpl).rendered.sh"
  perl -pe 's/\$\$\{/\$\{/g; s/\$\{[a-z][a-z0-9_]*\}/placeholder/g' "$template" >"$rendered"
  bash -n "$rendered"
done

printf 'Checking JavaScript syntax...\n'
node --check deploy/package-static.mjs
node --check deploy/verify-artifact.mjs

printf 'Checking repository policy...\n'
./scripts/check-policy.sh

printf 'Checking runtime, Nginx, and deployment contracts...\n'
bash tests/runtime/check.sh
bash tests/nginx/check.sh
bash tests/deployment/check.sh

printf 'Validation completed successfully.\n'
