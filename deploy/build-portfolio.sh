#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
release_manifest="$repository_root/deploy/releases/website-v1.0.0.json"
output_root=""
install_playwright_browser=false

while (($# > 0)); do
  case "$1" in
    --install-playwright-browser)
      install_playwright_browser=true
      shift
      ;;
    --output-dir)
      output_root="${2:-}"
      shift 2
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done

[[ -n "$output_root" ]]
output_root="$(realpath -m "$output_root")"
case "$output_root/" in
  "$repository_root/"*)
    printf '%s\n' 'artifact output must be outside the platform repository' >&2
    exit 1
    ;;
esac

if compgen -A variable | grep -Eq '^(VITE_|PUBLIC_|NEXT_PUBLIC_|REACT_APP_)'; then
  printf '%s\n' 'application runtime environment variables are not permitted' >&2
  exit 1
fi

readonly source_repository=https://github.com/rahulyadev/website
readonly release_tag=v1.0.0
readonly release_commit=0bfde1c170e2b27ec92d98504b6fa25d66543bed
readonly required_node=24.19.0
readonly required_npm=11.17.0
readonly temporary_root="$(mktemp -d)"
readonly source_root="$temporary_root/website"
readonly first_output="$temporary_root/package-first"
readonly second_output="$temporary_root/package-second"
trap 'rm -rf -- "$temporary_root"' EXIT

case "$temporary_root/" in
  "$repository_root/"*)
    printf '%s\n' 'temporary build source must be outside the platform repository' >&2
    exit 1
    ;;
esac

git clone --filter=blob:none --no-checkout "$source_repository" "$source_root"
[[ "$(git -C "$source_root" cat-file -t "refs/tags/$release_tag")" == "tag" ]]
[[ "$(git -C "$source_root" rev-parse "refs/tags/$release_tag^{}")" == "$release_commit" ]]
git -C "$source_root" checkout --detach "$release_commit"
[[ "$(git -C "$source_root" rev-parse HEAD)" == "$release_commit" ]]
[[ -z "$(git -C "$source_root" status --porcelain=v1 -uall)" ]]

[[ "$(node --version)" == "v$required_node" ]]
[[ "$(npm --version)" == "$required_npm" ]]

(
  cd -- "$source_root"
  npm ci
  if [[ "$install_playwright_browser" == true ]]; then
    [[ -x node_modules/.bin/playwright ]]
    node_modules/.bin/playwright install --with-deps chromium
  fi
  npm run verify
  npm run test:e2e
  npm run build
)

[[ -z "$(git -C "$source_root" status --porcelain=v1 -uall)" ]]
readonly source_commit_time="$(git -C "$source_root" show -s --format=%ct "$release_commit")"
readonly built_client="$source_root/build/client"
[[ -d "$built_client" ]]

node "$repository_root/deploy/package-static.mjs" \
  --input "$built_client" \
  --release-manifest "$release_manifest" \
  --source-commit-time "$source_commit_time" \
  --output-dir "$first_output"
node "$repository_root/deploy/package-static.mjs" \
  --input "$built_client" \
  --release-manifest "$release_manifest" \
  --source-commit-time "$source_commit_time" \
  --output-dir "$second_output"

artifact_name="website-v1.0.0-${release_commit}.tar.gz"
manifest_name="website-v1.0.0-${release_commit}.manifest.json"
first_artifact="$first_output/$artifact_name"
second_artifact="$second_output/$artifact_name"
first_manifest="$first_output/$manifest_name"
second_manifest="$second_output/$manifest_name"

cmp --silent "$first_artifact" "$second_artifact"
cmp --silent "$first_manifest" "$second_manifest"

artifact_sha="$(sha256sum "$first_artifact" | awk '{print $1}')"
manifest_sha="$(sha256sum "$first_manifest" | awk '{print $1}')"

node "$repository_root/deploy/verify-artifact.mjs" \
  --artifact "$first_artifact" \
  --manifest "$first_manifest" \
  --artifact-sha256 "$artifact_sha" \
  --manifest-sha256 "$manifest_sha"
node "$repository_root/deploy/verify-artifact.mjs" \
  --artifact "$second_artifact" \
  --manifest "$second_manifest" \
  --artifact-sha256 "$artifact_sha" \
  --manifest-sha256 "$manifest_sha"

install -d -m 0700 "$output_root"
install -m 0600 "$first_artifact" "$output_root/$artifact_name"
install -m 0600 "$first_manifest" "$output_root/$manifest_name"
install -m 0600 "$first_artifact.sha256" "$output_root/$artifact_name.sha256"
install -m 0600 "$first_manifest.sha256" "$output_root/$manifest_name.sha256"

cat >"$output_root/build-evidence.json" <<EVIDENCE
{
  "sourceRepository": "$source_repository",
  "tag": "$release_tag",
  "commit": "$release_commit",
  "node": "$required_node",
  "npm": "$required_npm",
  "artifact": "$artifact_name",
  "artifactSha256": "$artifact_sha",
  "manifest": "$manifest_name",
  "manifestSha256": "$manifest_sha",
  "deterministicPackagingRuns": 2
}
EVIDENCE
chmod 0600 "$output_root/build-evidence.json"

printf 'artifact=%s\n' "$output_root/$artifact_name"
printf 'artifact_sha256=%s\n' "$artifact_sha"
printf 'manifest=%s\n' "$output_root/$manifest_name"
printf 'manifest_sha256=%s\n' "$manifest_sha"
printf '%s\n' 'deterministic_packaging=true'
